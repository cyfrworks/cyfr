/* The night street: what waits on the person is the only neon that burns.
 *
 * This file holds the state the streams fold into and the renderers, which
 * are pure functions from that state to markup; street.js feeds it and
 * draws. Every value a stream carries is set as escaped text. */
(function (root) {
  'use strict';

  // ---------- the parts along the street, each a widget of the preferences ----------
  // zone: the wall above or the street level below; size: how it stands on the
  // wall; off: dark until the person lights it; streams: what the part reads,
  // whose worst state it shows. A part that is off reads on: it is only not drawn.
  const PARTS = {
    threads: { label: 'Threads', zone: 'wall', size: 'tall', streams: ['threads.changes'] },
    board: { label: 'Schedules and runs', zone: 'wall', size: 'tall', streams: ['schedules.changes', 'runs.changes'] },
    weather: { label: 'Weather', zone: 'wall', size: 'half', streams: ['feed:weather'] },
    crew: { label: 'Crew at work', zone: 'wall', size: 'half', streams: ['activity.changes'] },
    vpn: { label: 'VPN', zone: 'wall', size: 'tall', streams: ['feed:vpn'] },
    vault: { label: 'Vault', zone: 'wall', size: 'tall', streams: ['vault.changes'], off: true },
    cyfr: { label: 'CYFR', zone: 'level', size: 'box', streams: ['system.changes'] },
    apps: { label: 'Apps', zone: 'level', size: 'row', streams: ['components.changes'] },
    files: { label: 'Files', zone: 'level', size: 'box', streams: ['files.changes'] },
  };
  const ORDER = Object.keys(PARTS);

  // ---------- the light: what waits on the person, by kind ----------
  const KINDS = {
    approval: { word: 'approve', hue: '#ff3d9a', light: 'burn' },
    confirmation: { word: 'confirm', hue: '#b48cff', light: 'burn' },
    grant: { word: 'grant?', hue: '#ffb020', light: 'burn' },
    failed_run: { word: 'failed', hue: '#ff4b3a', light: 'sputter' },
    failed_schedule: { word: 'failed', hue: '#ff4b3a', light: 'sputter' },
    file_offer: { word: 'offer', hue: '#2ee6ff', light: 'burn' },
  };

  const EMPTY = () => ({
    attention: new Map(),
    threads: new Map(),
    runs: new Map(),
    schedules: new Map(),
    activity: new Map(),
    components: new Map(),
    vault: new Map(),
    files: new Map(),
    system: new Map(),
    feeds: { weather: new Map(), vpn: new Map() },
    installed: [],
    lines: {},
    prefs: {},
    person: null,
    appearance: null,
  });

  const isItem = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
  const text = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');
  const time = (v) => { const t = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isNaN(t) ? null : t; };

  // ---------- holding each stream by the delivery contract ----------
  // Every stream the street reads, opened once at start and kept open: the
  // state field its items fill, the field that names an item (none: the
  // stream is one item) and the kind that removes one.
  const HOLD = {
    'attention.changes': { field: 'attention', key: 'id', removal: 'removed' },
    'threads.changes': { field: 'threads', key: 'id', removal: 'removed' },
    'runs.changes': { field: 'runs', key: 'execution_id' },
    'schedules.changes': { field: 'schedules', key: 'schedule_id', removal: 'removed' },
    'activity.changes': { field: 'activity', key: 'id', removal: 'ended' },
    'components.changes': { field: 'components', key: 'ref', removal: 'removed' },
    'vault.changes': { field: 'vault', key: 'name', removal: 'removed' },
    'files.changes': { field: 'files', key: 'id', removal: 'removed' },
    'system.changes': { field: 'system' },
    'feed:weather': { feed: 'weather', key: 'binding' },
    'feed:vpn': { feed: 'vpn', key: 'binding' },
  };
  const OPEN = Object.keys(HOLD);
  const MAX_RUNS = 20;

  const itemsOf = (s, key) => (HOLD[key].feed ? s.feeds[HOLD[key].feed] : s[HOLD[key].field]);
  function setItems(s, key, m) { if (HOLD[key].feed) s.feeds[HOLD[key].feed] = m; else s[HOLD[key].field] = m; }
  // What the street holds is what it shows: the waiting kinds it knows, and
  // root runs (the board's, and the only ones that run again).
  function admit(key, item) {
    if (key === 'attention.changes') return !!KINDS[item.kind];
    if (key === 'runs.changes') return !item.parent_execution_id;
    return true;
  }
  const newestRuns = (m) => [...m.values()].sort((a, b) => (time(b.started_at) || 0) - (time(a.started_at) || 0));
  function capRuns(m) {
    if (m.size > MAX_RUNS) for (const r of newestRuns(m).slice(MAX_RUNS)) m.delete(text(r.execution_id));
    return m;
  }
  // A stream's line: its state, the highest revision heard per item, and the
  // picture it gathers apart until that picture's snapshot.
  function line(s, key) {
    return s.lines[key] || (s.lines[key] = { state: 'opening', revs: new Map(), gather: new Map(), grevs: new Map(), asOf: null, at: null, retryAt: null });
  }
  // A stream opened (again): its first picture is gathered apart.
  function opening(s, key) { const L = line(s, key); L.gather = new Map(); L.grevs = new Map(); }
  function cleared(s, key, state) {
    const L = line(s, key);
    setItems(s, key, new Map());
    Object.assign(L, { state, revs: new Map(), gather: null });
  }
  // A first open refused: `forbidden` is not granted, `unavailable` opens
  // again at `retryAt`, a feed nobody bound is simply unbound, and anything
  // else could not be read.
  function refused(s, key, code, retryAt) {
    if (code === 'unavailable') { Object.assign(line(s, key), { state: 'unavailable', retryAt: retryAt || null, gather: null }); return; }
    cleared(s, key, code === 'forbidden' ? 'forbidden' : HOLD[key].feed && code === 'not_found' ? 'unbound' : 'unread');
  }

  // One event a stream's handler heard, held by the delivery contract
  // (`Compendium.Canvas.catalog/1`). Answers 'change' for a live change
  // held, 'picture' when a picture replaced what was held or a denial
  // cleared it, 'state' for a state, and '' for nothing new.
  function hear(s, key, ev) {
    if (!HOLD[key] || !isItem(ev)) return '';
    const L = line(s, key);
    if (ev.event === 'resync') { opening(s, key); return ''; }
    if (ev.event === 'snapshot') {
      if (L.gather) { setItems(s, key, key === 'runs.changes' ? capRuns(L.gather) : L.gather); L.revs = L.grevs; L.gather = null; }
      Object.assign(L, { state: 'live', asOf: time(ev.at), at: null, retryAt: null });
      return 'picture';
    }
    if (ev.event === 'stale') { Object.assign(L, { state: 'stale', at: time(ev.at) || L.asOf }); return 'state'; }
    if (ev.event === 'unavailable') { Object.assign(L, { state: 'unavailable', retryAt: time(isItem(ev.data) ? ev.data.retry_at : null) }); return 'state'; }
    if (ev.event === 'denied') { cleared(s, key, 'denied'); return 'picture'; }
    const item = ev.data;
    if (!isItem(item)) return '';
    const H = HOLD[key];
    const k = H.key ? text(item[H.key]) : '*';
    // A change that names no item is a notice, never held.
    if (!k) return '';
    const rev = Number.isInteger(ev.revision) ? ev.revision : Number.isInteger(item.revision) ? item.revision : null;
    const into = L.gather || itemsOf(s, key), revs = L.gather ? L.grevs : L.revs;
    // An equal revision is the same change heard twice; a lower one is older.
    if (rev !== null && revs.has(k) && rev <= revs.get(k)) return '';
    if (rev !== null) revs.set(k, rev);
    if (H.removal && item.kind === H.removal) into.delete(k);
    else if (admit(key, item)) { into.set(k, item); if (key === 'runs.changes' && !L.gather) capRuns(into); }
    else into.delete(k);
    return L.gather ? '' : 'change';
  }

  // The latest result of a feed, the one item of the system stream, the runs newest first.
  function feedOf(s, name) {
    let best = null;
    for (const f of s.feeds[name].values()) if (!best || (time(f.at) || 0) >= (time(best.at) || 0)) best = f;
    return best;
  }
  const sysOf = (s) => s.system.get('*') || null;
  const runsOf = (s) => newestRuns(s.runs);

  // ---------- how a part's streams stand: the worst of them ----------
  const RANK = { opening: 0, live: 0, unbound: 0, stale: 1, unavailable: 2, unread: 3, forbidden: 4, denied: 5 };
  function lineOf(s, streams) {
    let worst = null;
    for (const key of streams) { const L = s.lines[key] || { state: 'opening' }; if (!worst || RANK[L.state] > RANK[worst.state]) worst = L; }
    return worst || { state: 'live' };
  }
  // Ended or refused: the part's picture is gone, and it says why instead of showing an empty part.
  const isDark = (s, streams) => RANK[lineOf(s, streams).state] >= 3;

  // ---------- preferences: which parts are on, and in what order ----------
  function widgetEntry(prefs, id) {
    const w = isItem(prefs) && isItem(prefs.widgets) ? prefs.widgets[id] : null;
    return isItem(w) ? w : null;
  }
  function isOn(prefs, id) {
    const w = widgetEntry(prefs, id);
    if (w && typeof w.on === 'boolean') return w.on;
    return !PARTS[id].off;
  }
  function order(prefs) {
    const at = (id) => { const w = widgetEntry(prefs, id); return w && Number.isInteger(w.place) ? w.place : ORDER.indexOf(id); };
    return ORDER.slice().sort((a, b) => at(a) - at(b) || ORDER.indexOf(a) - ORDER.indexOf(b));
  }
  // The write a breaker's flip makes: the part's whole entry.
  function flipDoc(prefs, id) {
    const o = order(prefs);
    return { widgets: { [id]: { on: !isOn(prefs, id), place: o.indexOf(id) } } };
  }
  // The write a move makes: every part's entry, in its new place.
  function moveDoc(prefs, id, dir) {
    const o = order(prefs);
    const zone = PARTS[id].zone;
    const i = o.indexOf(id);
    let j = i + dir;
    while (j >= 0 && j < o.length && PARTS[o[j]].zone !== zone) j += dir;
    if (j < 0 || j >= o.length) return null;
    o.splice(i, 1); o.splice(j, 0, id);
    const widgets = {};
    o.forEach((p, n) => { widgets[p] = { on: isOn(prefs, p), place: n }; });
    return { widgets };
  }
  // ---------- words ----------
  const esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const MIN = 60000;
  function clock(s) {
    const ap = s.appearance || {};
    const opts = (o) => { try { return new Intl.DateTimeFormat(ap.locale || undefined, Object.assign({ timeZone: ap.time_zone || undefined }, o)); } catch (e) { return new Intl.DateTimeFormat(undefined, o); } };
    const hmF = opts({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
    const dayF = opts({ year: 'numeric', month: 'numeric', day: 'numeric' });
    const wdF = opts({ weekday: 'short' });
    const longF = opts({ weekday: 'long', day: 'numeric', month: 'short' });
    // The day a time falls on in the person's zone, as a count of days.
    const dayNo = (t) => {
      const p = {};
      for (const part of dayF.formatToParts(new Date(t))) p[part.type] = Number(part.value);
      return Math.round(Date.UTC(p.year, p.month - 1, p.day) / 86400000);
    };
    return {
      hm: (t) => hmF.format(new Date(t)),
      long: (t) => longF.format(new Date(t)),
      when(t, now) {
        const dd = dayNo(t) - dayNo(now);
        if (dd === 0) return hmF.format(new Date(t));
        if (dd === -1) return 'yesterday';
        if (dd === 1) return 'tomorrow ' + hmF.format(new Date(t));
        return wdF.format(new Date(t)) + (t > now ? ' ' + hmF.format(new Date(t)) : '');
      },
    };
  }
  function until(t, now) {
    const m = Math.round((t - now) / MIN);
    if (m <= 0) return 'due now';
    if (m < 60) return 'in ' + m + ' min';
    return null;
  }
  const since = (t, now) => { const m = Math.max(0, Math.round((now - t) / MIN)); return m < 60 ? m + ' min' : Math.floor(m / 60) + ' h ' + (m % 60) + ' min'; };
  const num = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  const words = (v) => text(v).replace(/_/g, ' ');
  // "catalyst:local.openai:1.4.1" as a person reads it: "openai".
  function compName(reference) {
    const named = text(reference).split(':')[1] || text(reference);
    return named.includes('.') ? named.slice(named.indexOf('.') + 1) : named;
  }
  const versionless = (ref) => { const p = text(ref).split(':'); return p.length === 3 ? p[0] + ':' + p[1] : text(ref); };
  // Bytes as Prism shows them, 1024 to the next unit, in the cap's unit: "38 of 100 GB", or "38 GB" with no cap.
  function storage(y) {
    if (!isNum(y.storage_used)) return null;
    const cap = isNum(y.storage_cap) && y.storage_cap > 0 ? y.storage_cap : null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let u = 0;
    while (u < units.length - 1 && (cap || y.storage_used) >= Math.pow(1024, u + 1)) u++;
    const f = (b) => { const v = b / Math.pow(1024, u); return v >= 10 || Number.isInteger(v) ? String(Math.round(v)) : v.toFixed(1); };
    return { text: f(y.storage_used) + (cap ? ' of ' + f(cap) : '') + ' ' + units[u], pct: cap ? Math.max(0, Math.min(100, Math.round((y.storage_used / cap) * 100))) : 0 };
  }
  // How the CYFR stands, line by line as the junction box lists it: [lamp tone, words].
  function systemLines(y) {
    const out = [];
    const health = { ok: ['ok', 'healthy'], degraded: ['bad', 'degraded'], low_storage: ['warn', 'low on storage'] }[y.health];
    if (health) out.push(health);
    if (typeof y.model_connected === 'boolean') out.push(y.model_connected ? ['ok', 'model connected'] : ['bad', 'no model']);
    if (Number.isInteger(y.crew_total)) {
      const ready = Number.isInteger(y.crew_ready) ? y.crew_ready : 0;
      out.push([ready >= y.crew_total ? 'ok' : 'warn', 'crew ' + ready + ' of ' + y.crew_total]);
    }
    return out;
  }

  // Letters of a sign as spans, so a failing tube can lose some of them.
  function tube(t, light) {
    if (light !== 'sputter' || t.length < 3) return '<span class="tube">' + esc(t) + '</span>';
    const dead = new Set([1, Math.max(2, t.length - 2)]);
    const stut = Math.min(t.length - 1, 3);
    return '<span class="tube tube--letters" aria-label="' + esc(t) + '">' + [...t].map((ch, i) =>
      '<span aria-hidden="true" class="' + (dead.has(i) ? 'dead' : i === stut ? 'stutter' : '') + '">' + esc(ch) + '</span>').join('') + '</span>';
  }
  const lightAttrs = (lit) => lit ? ' data-light="' + lit.light + '" style="--hue:' + lit.hue + '" data-att="' + esc(lit.id) + '"' : '';
  const tag = (lit) => lit ? '<span class="tag">' + tube(lit.word, lit.light) + '</span>' : '';

  // ---------- what burns: every waiting item, by the sign it lights ----------
  // ui.going holds the items answered a moment ago, still switching off.
  function waiting(s, ui) {
    const out = [];
    for (const a of s.attention.values()) {
      const k = KINDS[a.kind];
      const d = isItem(a.destination) ? a.destination : {};
      let target = null;
      if (a.kind === 'approval') target = 'thread:' + text(d.ref);
      else if (a.kind === 'failed_run') target = 'failed:' + text(a.id);
      else if (a.kind === 'failed_schedule') target = 'schedule:' + text(a.id);
      else if (a.kind === 'file_offer') target = 'offer:' + text(a.id);
      else if (a.kind === 'confirmation') target = 'cyfr';
      // An offer reads with its sender, from the locker's stream.
      const offer = a.kind === 'file_offer' ? s.files.get(text(a.id)) : null;
      const label = a.kind === 'failed_run' ? compName(a.label || a.id) : text(a.label) + (offer && isStr(offer.from) ? ' from ' + offer.from : '');
      out.push({ id: 'a:' + text(a.id), kind: a.kind, target, label, since: time(a.since), page: d.kind === 'page' ? text(d.page) : null, item: a, word: k.word, hue: k.hue, light: k.light });
    }
    // An installed app whose grant is not current waits on the person too.
    for (const app of s.installed) {
      const c = s.components.get(versionless(app.ref));
      if (c && c.grant_current === false) out.push({ id: 'g:' + app.ref, kind: 'grant', target: 'app:' + versionless(app.ref), label: app.name, since: null, page: null, ref: versionless(app.ref), word: 'grant?', hue: KINDS.grant.hue, light: 'burn' });
    }
    for (const w of out) if (ui && ui.going && ui.going[w.id]) w.light = 'out';
    if (ui && ui.going) for (const id of Object.keys(ui.going)) if (!out.find((w) => w.id === id) && ui.gone[id]) out.push(Object.assign({}, ui.gone[id], { light: 'out' }));
    return out.sort((a, b) => (a.since || 0) - (b.since || 0));
  }
  function litTable(list) {
    const m = new Map();
    for (const w of list) if (!m.has(w.target)) m.set(w.target, w);
    return m;
  }
  const countWaiting = (list) => list.filter((w) => w.light !== 'out').length;

  // ---------- small drawn glyphs ----------
  const G = {
    breaker: '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h6"/>',
    refresh: '<path d="M19 12a7 7 0 1 1-2-5M19 4v4h-4"/>',
    lock: '<rect x="6" y="11" width="12" height="9" rx="2"/><path d="M9 11V8a3 3 0 0 1 6 0v3"/>',
    file: '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/>',
    aqua: '<path d="M12 3c3 4 6 7 6 11a6 6 0 0 1-12 0c0-4 3-7 6-11z"/>',
  };
  const icon = (n, cls) => '<svg class="ico ' + (cls || '') + '" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' + G[n] + '</svg>';
  const chase = () => '<svg class="chase" aria-hidden="true" focusable="false"><rect pathLength="100" rx="9"/></svg>';
  const lamp = (tone, label) => '<span class="lamp lamp--' + tone + '"' + (label ? ' role="img" aria-label="' + esc(label) + '"' : ' aria-hidden="true"') + '></span>';
  // What a part says of its streams when they are not live: a tired picture
  // keeps its time, one out for now says when it tries again, and one ended
  // or refused says so in the street's words, never the refusal's.
  function note(s, streams, C) {
    const L = lineOf(s, streams);
    const say = L.state === 'stale' ? 'as of ' + (L.at ? C.hm(L.at) : 'a while ago')
      : L.state === 'unavailable' ? 'Out for now · trying again ' + (L.retryAt ? 'at ' + C.hm(L.retryAt) : 'soon')
        : L.state === 'unread' ? 'This could not be read.'
          : L.state === 'forbidden' ? 'Not granted, so it stays dark.'
            : L.state === 'denied' ? 'No longer granted, so it went dark.' : '';
    return say ? '<span class="refused refused--' + L.state + '">' + esc(say) + '</span>' : '';
  }

  // ---------- parts ----------
  function renderThreads(s, lit, ui, C) {
    const list = [...s.threads.values()].sort((a, b) => (time(b.last_activity) || 0) - (time(a.last_activity) || 0)).slice(0, 6);
    const rows = list.map((t, i) => {
      const L = lit.get('thread:' + text(t.id));
      const people = Array.isArray(t.people) ? t.people.length : 0;
      const who = t.kind === 'own' ? 'with AQUA' : people === 2 ? 'pair' : people + (people === 1 ? ' person' : ' people');
      const last = time(t.last_activity);
      const unread = Number.isInteger(t.unread) && t.unread > 0 ? t.unread : 0;
      const news = unread ? '<span class="news">' + '<i></i>'.repeat(Math.min(unread, 3)) + unread + ' new</span>' : '';
      return '<li class="hang" style="--tilt:' + ([-1.2, 0.9, -0.6, 1.3, -0.9, 0.7][i % 6]) + 'deg">' +
        '<button class="sign plaque plaque--' + (t.kind === 'own' ? 'own' : 'shared') + '" data-target="thread:' + esc(t.id) + '"' + lightAttrs(L) + '>' +
        '<span class="plaque__title">' + tube(text(t.title) || 'Untitled', L && L.light) + '</span>' +
        '<span class="meta">' + esc(who) + (last ? ' · ' + esc(C.when(last, ui.now)) : '') + news + (t.waits_on_you && !L ? ' · waits on you' : '') + tag(L) + '</span></button></li>';
    }).join('');
    const empty = !list.length && !isDark(s, PARTS.threads.streams) ? '<li class="hang"><span class="sign plaque plaque--shared plaque--empty"><span class="plaque__title tube">No threads yet</span><span class="meta">a chat with AQUA hangs here</span></span></li>' : '';
    return '<h2 class="vh" id="h-threads">Threads</h2>' + note(s, PARTS.threads.streams, C) + '<ul class="plaques">' + rows + empty + '</ul>';
  }

  function renderBoard(s, lit, ui, C) {
    const schedules = [...s.schedules.values()].sort((a, b) => (a.status === 'paused') - (b.status === 'paused') || (time(a.next_run_at) || Infinity) - (time(b.next_run_at) || Infinity));
    const next = schedules.slice(0, 5).map((x) => {
      const id = text(x.schedule_id);
      const L = lit.get('schedule:' + id);
      const paused = x.status === 'paused';
      const at = time(x.next_run_at), lastAt = time(x.last_run_at);
      const due = paused ? 'paused' : at ? (until(at, ui.now) || C.when(at, ui.now)) : 'not planned';
      const errors = Number(x.error_count) || 0;
      const meta = paused ? (lastAt ? 'last ' + C.when(lastAt, ui.now) : 'never ran') : num(Number(x.run_count) || 0) + ' runs' + (errors ? ' · ' + errors + ' error' + (errors > 1 ? 's' : '') : '');
      return '<li><button class="row' + (paused ? ' row--paused' : '') + '" data-target="schedule:' + esc(id) + '"' + lightAttrs(L) + '>' +
        '<span class="dot when">' + esc(paused || !at ? '--:--' : C.hm(at)) + '</span>' +
        '<span class="dot what">' + (L ? tube(text(x.name), L.light) : esc(text(x.name) || compName(x.reference))) + '</span>' +
        '<span class="row__meta">' + esc(due) + ' · ' + esc(meta) + '</span>' +
        (L ? lamp('bad', 'failed') : errors ? lamp('warn', errors + ' errors') : paused ? lamp('off', 'paused') : lamp('ok', 'fine')) + '</button></li>';
    }).join('');
    // A failure that waits on the person never scrolls off the board; the
    // newest others fill the rest. It lights the row of the run it names.
    const fails = [...lit.values()].filter((w) => w.kind === 'failed_run');
    const failOf = new Map(fails.map((w) => [text(isItem(w.item.destination) ? w.item.destination.ref : ''), w]));
    const rows = runsOf(s).map((r) => ({ r, L: failOf.get(text(r.execution_id)) || null }));
    for (const w of fails) if (!rows.some((x) => x.L === w)) rows.push({ r: null, L: w, ref: text(w.item.id) });
    // The failures that wait first, then the newest others: the page hides
    // what its board has no room for (street.js fitBoard), and its last
    // line counts the failures it hid.
    const litRows = rows.filter((x) => x.L);
    const keep = litRows.slice(0, 6).concat(rows.filter((x) => !x.L)).slice(0, Math.max(4, Math.min(6, litRows.length)));
    const ran = rows.filter((x) => keep.includes(x)).map(({ r: item, L, ref }) => {
      const reference = item ? text(item.reference) : ref;
      const name = compName(reference);
      const kind = item ? item.kind : 'failed';
      const err = item && isItem(item.error) ? item.error : null;
      const out = kind === 'failed' ? (err ? words(err.class) + ' · ' + words(err.cause) : 'failed') : kind === 'started' ? 'running' : kind === 'cancelled' ? 'cancelled' : typeof item.duration_ms === 'number' ? (item.duration_ms / 1000).toFixed(1) + ' s' : 'done';
      const started = item ? time(item.started_at) : null;
      const at = started ? C.hm(started) : L && L.since ? C.hm(L.since) : '--:--';
      const target = L ? L.target : 'run:' + text(item.execution_id);
      return '<li' + (L ? ' data-lit="1"' : '') + '><button class="row row--ran' + (kind === 'started' ? ' row--working' : '') + '" data-target="' + esc(target) + '"' + lightAttrs(L) + '>' +
        '<span class="dot when">' + esc(at) + '</span>' +
        '<span class="dot what">' + (L ? tube(name, L.light) : esc(name)) + '</span>' +
        '<span class="row__meta">' + (L ? tube(out, 'burn') : esc(out)) + '</span>' +
        (kind === 'completed' ? lamp('ok', 'finished') : kind === 'started' ? lamp('work', 'running') : kind === 'cancelled' ? lamp('off', 'cancelled') : lamp('bad', 'failed')) + '</button></li>';
    }).join('');
    const none = (t) => '<li><p class="row row--none">' + esc(t) + '</p></li>';
    const dark = isDark(s, PARTS.board.streams);
    return '<div class="sign board"><h2 id="h-board" class="board__head">' + tube('Schedules') + '</h2>' + note(s, PARTS.board.streams, C) +
      '<h3 class="board__sub">Next</h3><ul class="rows">' + (next || (dark ? '' : none('Nothing is scheduled.'))) + '</ul>' +
      '<h3 class="board__sub">Lately</h3><ul class="rows rows--ran" data-lit-total="' + litRows.length + '">' + (ran || (dark ? '' : none('No runs yet.'))) + '</ul>' +
      '<p class="board__more" hidden></p></div>';
  }

  // A feed's result is the feed's own shape: the sign reads the few fields a
  // weather result commonly names, and the feed's label and time otherwise.
  const pick = (o, names, test) => { for (const n of names) if (isItem(o) && test(o[n])) return o[n]; return undefined; };
  const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
  const isStr = (v) => typeof v === 'string' && v !== '' && v.length <= 80;
  function weatherOf(f) {
    const r = isItem(f.result) ? f.result : {};
    const temp = pick(r, ['temp_c', 'temperature_c', 'temperature', 'temp'], isNum);
    const hours = Array.isArray(r.next_hours) ? r.next_hours.filter(isNum).slice(0, 4) : [];
    return {
      temp: temp,
      place: pick(r, ['place', 'city', 'location', 'name'], isStr) || text(f.label),
      sky: pick(r, ['sky', 'condition', 'summary', 'description'], isStr) || '',
      wind: pick(r, ['wind_kmh', 'wind'], isNum),
      hours,
    };
  }
  function feedActions(f, cls) {
    const acts = Array.isArray(f.actions) ? f.actions.filter((a) => isItem(a) && isStr(a.name)).slice(0, 3) : [];
    return acts.map((a) => '<button class="btn ' + (cls || '') + '" data-act="feed-press" data-binding="' + esc(f.binding) + '" data-action="' + esc(a.name) + '">' + esc(text(a.label) || a.name) + '</button>').join('');
  }
  function unbound(id, title, sentence) {
    return '<h2 id="h-' + id + '" class="unbound__head">' + tube(title) + '</h2><p class="meta">' + esc(sentence) + '</p>' +
      '<button class="btn btn--ask" data-act="ask" data-widget="' + id + '">' + icon('aqua') + 'Ask AQUA</button>';
  }

  // A feed's sign with no result: dark while it opens, saying why when it is
  // not read, and offering AQUA's help when no feed is bound.
  function noFeed(s, id, title, C) {
    const n = note(s, PARTS[id].streams, C);
    return n || lineOf(s, PARTS[id].streams).state === 'opening' ? '<h2 id="h-' + id + '" class="unbound__head">' + tube(title) + '</h2>' + n
      : unbound(id, title, 'No ' + (id === 'vpn' ? 'VPN' : id) + ' feed is bound yet.');
  }

  function renderWeather(s, lit, ui, C) {
    const f = feedOf(s, 'weather');
    if (!f) return '<div class="sign roofsign roofsign--dark">' + noFeed(s, 'weather', 'Weather', C) + '</div>';
    const w = weatherOf(f);
    const at = time(f.at);
    const hi = w.hours.length ? Math.max(...w.hours) : 0, lo = w.hours.length ? Math.min(...w.hours) - 3 : 0;
    const bars = w.hours.map((c, i) => '<li style="--h:' + Math.round(((c - lo) / Math.max(1, hi - lo)) * 100) + '%" aria-label="in ' + (i + 1) + ' h, ' + c + ' degrees"><span class="bar"></span><b>' + esc(Math.round(c)) + '°</b></li>').join('');
    const refresh = Array.isArray(f.actions) ? f.actions.find((a) => isItem(a) && /refresh|update|reload/i.test(text(a.name))) || f.actions[0] : null;
    return '<div class="sign roofsign' + (ui.working.weather ? ' is-working' : '') + '" data-target="feed:weather">' +
      '<h2 id="h-weather" class="vh">Weather</h2>' +
      '<button class="big" data-target="feed:weather" aria-label="Weather' + (w.place ? ' in ' + esc(w.place) : '') + '">' + tube(w.temp !== undefined ? Math.round(w.temp) + '°' : '—') + '</button>' +
      '<span class="roofsign__where"><b>' + esc(w.place) + '</b>' + (w.sky ? '<span>' + esc(w.sky) + '</span>' : '') + (w.wind !== undefined ? '<span>wind ' + esc(w.wind) + ' km/h</span>' : '') + '<span class="meta">' + (ui.working.weather ? 'refreshing…' : at ? 'updated ' + esc(C.hm(at)) : '') + '</span>' + note(s, PARTS.weather.streams, C) + '</span>' +
      '<ol class="hours" aria-label="Next hours">' + bars + '</ol>' +
      (refresh && isItem(refresh) && isStr(refresh.name) ? '<button class="btn btn--round" data-act="feed-press" data-feed="weather" data-binding="' + esc(f.binding) + '" data-action="' + esc(refresh.name) + '" aria-label="' + esc(text(refresh.label) || 'Refresh') + '">' + icon('refresh') + '</button>' : '') +
      chase() + '</div>';
  }

  function renderCrew(s, lit, ui, C) {
    const jobs = [...s.activity.values()].sort((a, b) => (time(a.since) || 0) - (time(b.since) || 0));
    const n = note(s, PARTS.crew.streams, C);
    if (!jobs.length) return '<button class="sign crewsign" data-target="crew"><span class="crewsign__head" id="h-crew">' + tube('Crew') + '</span>' + (isDark(s, PARTS.crew.streams) ? '' : '<span class="meta">No one is at work.</span>') + n + '</button>';
    const j = jobs[0], at = time(j.since);
    return '<button class="sign crewsign is-working" data-target="crew">' +
      '<span class="vh" id="h-crew">Crew at work</span>' +
      '<span class="crewsign__head">' + tube(text(j.member)) + '</span>' +
      '<span class="crewsign__title">' + esc(text(j.title) || words(j.status) || 'working') + (jobs.length > 1 ? ' · ' + (jobs.length - 1) + ' more at work' : '') + '</span>' +
      '<span class="meta">' + (j.asked_by ? 'for ' + esc(j.asked_by) : '') + (at ? ' · since ' + esc(C.hm(at)) + ' · ' + esc(since(at, ui.now)) : '') + '</span>' + n +
      chase() + '</button>';
  }

  function renderVpn(s, lit, ui, C) {
    const f = feedOf(s, 'vpn');
    if (!f) return '<div class="mast mast--dark"><div class="sign mastbox">' + noFeed(s, 'vpn', 'VPN', C) + '</div></div>';
    const r = isItem(f.result) ? f.result : {};
    const st = pick(r, ['state', 'status'], isStr) || '';
    const server = pick(r, ['server', 'location'], isStr) || '';
    const servers = Array.isArray(r.servers) ? r.servers.filter(isStr).slice(0, 6) : [];
    const on = /^(connected|up|on)$/i.test(st);
    const working = /connecting|starting/i.test(st);
    const arms = servers.map((sv, i) => '<li class="arm arm--' + (i % 2 ? 'r' : 'l') + '"><span class="dish' + (sv === server && on ? ' dish--on' : '') + '">' + (sv === server && on ? lamp('ok', 'connected') : sv === server && working ? lamp('work', 'connecting') : lamp('off')) + '<span>' + esc(sv) + '</span></span></li>').join('');
    const down = pick(r, ['down_mbps'], isNum);
    const at = time(f.at);
    return '<div class="mast"><span class="mast__tip" aria-hidden="true"></span><ul class="arms" aria-label="Servers">' + arms + '</ul>' +
      '<div class="sign mastbox' + (working ? ' is-working' : '') + '" data-target="feed:vpn"><h2 id="h-vpn" class="mastbox__head"><button data-target="feed:vpn">' + tube('VPN') + '</button></h2>' +
      '<p class="mastbox__state">' + esc([st, server].filter(Boolean).join(' · ') || text(f.label)) + '</p>' +
      '<p class="meta">' + (down !== undefined ? esc(down) + ' Mb/s down' : at ? 'updated ' + esc(C.hm(at)) : '&nbsp;') + '</p>' + note(s, PARTS.vpn.streams, C) + '<div class="mastbox__acts">' + feedActions(f) + '</div>' + chase() + '</div></div>';
  }

  function renderVault(s, lit, ui, C) {
    const rows = [...s.vault.values()].sort((a, b) => (a.status === 'fine') - (b.status === 'fine') || text(a.name).localeCompare(text(b.name))).slice(0, 6).map((v) => {
      const fine = v.status === 'fine';
      const st = fine ? 'fine' : 'needs re-authorisation';
      return '<li><button class="row row--vault" data-target="vault:' + esc(v.name) + '">' + icon('lock') + '<span class="what">' + esc(v.name) + '</span><span class="row__meta">' + esc(words(v.type)) + ' · ' + esc(st) + '</span>' + lamp(fine ? 'ok' : 'bad', st) + '</button></li>';
    }).join('');
    const empty = isDark(s, PARTS.vault.streams) ? '' : '<li><p class="row row--none">The vault is empty.</p></li>';
    return '<div class="sign strongbox"><h2 id="h-vault" class="strongbox__head">' + tube('Vault') + '</h2>' + note(s, PARTS.vault.streams, C) + '<ul class="rows">' + (rows || empty) + '</ul><p class="meta">Names and status only.</p></div>';
  }

  function renderApps(s, lit, ui, C) {
    const shops = s.installed.slice(0, 8).map((app) => {
      const ref = versionless(app.ref);
      const L = lit.get('app:' + ref);
      const c = s.components.get(ref);
      const update = c && c.update_available === true;
      const mark = app.icon ? '<span class="shop__ico shop__ico--emoji" aria-hidden="true">' + esc(app.icon) + '</span>' : '<span class="shop__ico shop__ico--mark" aria-hidden="true">' + esc(([...text(app.name)][0] || '?').toUpperCase()) + '</span>';
      return '<li class="shop' + (app.open ? ' shop--open' : '') + '">' +
        '<button class="sign awning" data-target="app:' + esc(ref) + '"' + lightAttrs(L) + (L ? '' : ' tabindex="-1" aria-hidden="true"') + '>' + (L ? tube(L.word, L.light) : tube(text(app.name))) + '</button>' +
        '<button class="window" data-act="open-app" data-app="' + esc(app.ref) + '" aria-label="Open ' + esc(app.name) + (app.open ? ', open' : '') + (update ? ', update available' : '') + '">' +
        '<span class="shutter" aria-hidden="true"></span>' + mark +
        '<span class="shop__name">' + esc(app.name) + '</span>' +
        (app.open ? '<span class="shop__state">open</span>' : '') +
        (update ? '<span class="sticker">' + lamp('warn') + 'update</span>' : '') + '</button></li>';
    }).join('');
    return '<h2 class="vh" id="h-apps">Apps</h2>' + note(s, PARTS.apps.streams, C) + '<ul class="shops">' + (shops || '<li class="shop shop--none"><p class="meta">No apps yet. Ask AQUA to make you one.</p></li>') + '</ul>';
  }

  // The locker: offers waiting for the person first, with their sender, then the newest files.
  function renderFiles(s, lit, ui, C) {
    const all = [...s.files.values()];
    const offers = all.filter((f) => f.kind === 'offer').sort((a, b) => (time(a.changed_at) || 0) - (time(b.changed_at) || 0));
    const recent = all.filter((f) => f.kind === 'file').sort((a, b) => (time(b.changed_at) || 0) - (time(a.changed_at) || 0));
    const cells = offers.concat(recent).slice(0, 4).map((f) => {
      const offer = f.kind === 'offer';
      const L = offer ? lit.get('offer:' + text(f.id)) : null;
      const at = time(f.changed_at);
      const meta = offer ? (isStr(f.from) ? 'from ' + f.from : 'offered') + (at ? ' · ' + C.hm(at) : '') : at ? C.when(at, ui.now) : '';
      return '<li><button class="' + (offer ? 'sign cubby cubby--offer' : 'cubby') + '" data-target="' + (offer ? 'offer:' : 'file:') + esc(f.id) + '"' + lightAttrs(L) + '>' + icon('file') +
        '<span class="cubby__name">' + (L ? tube(text(f.name), L.light) : esc(f.name)) + '</span><span class="meta">' + esc(meta) + '</span></button></li>';
    }).join('');
    const empty = isDark(s, PARTS.files.streams) ? '' : '<li><button class="cubby cubby--empty" data-act="settings" data-page="files">' + icon('file') + '<span class="cubby__name">Files</span><span class="meta">no files yet</span></button></li>';
    return '<div class="locker"><h2 id="h-files" class="locker__head">' + tube('Files') + '</h2>' + note(s, PARTS.files.streams, C) + '<ul class="cubbies">' + (cells || empty) + '</ul></div>';
  }

  // The junction box: how the CYFR stands, from its one status item.
  function renderCyfr(s, lit, ui, C) {
    const L = lit.get('cyfr');
    const y = sysOf(s);
    const jl = (tone, words) => '<span class="jl">' + lamp(tone) + esc(words) + '</span>';
    const st = y ? storage(y) : null;
    return '<button class="sign junction" data-target="cyfr"' + lightAttrs(L) + '>' +
      '<span class="junction__head" id="h-cyfr">' + tube('CYFR') + (y && isStr(y.version) ? '<span class="ver">' + esc(y.version) + '</span>' : '') + tag(L) + '</span>' +
      (y ? systemLines(y).map(([tone, words]) => jl(tone, words)).join('') : '') +
      (st ? '<span class="gauge" style="--p:' + st.pct + '%"><span class="vh">Storage </span>' + esc(st.text) + '</span>' : '') +
      (y && y.update_available === true ? jl('warn', 'update available') : '') +
      note(s, PARTS.cyfr.streams, C) + '</button>';
  }

  const RENDER = { threads: renderThreads, board: renderBoard, weather: renderWeather, crew: renderCrew, vpn: renderVpn, vault: renderVault, cyfr: renderCyfr, apps: renderApps, files: renderFiles };

  // The puddle: every waiting item reflected, so each stays reachable when its part is off or covered.
  function renderPuddle(s, list, ui, C) {
    const off = (w) => {
      const kind = w.target.split(':')[0];
      const part = { thread: 'threads', failed: 'board', schedule: 'board', app: 'apps', offer: 'files', cyfr: 'cyfr' }[kind];
      return part && !isOn(s.prefs, part);
    };
    const items = list.map((w) => '<li><button class="ripple" data-ref="' + esc(w.target) + '" style="--hue:' + w.hue + '"' + (w.light === 'out' ? ' data-going="1"' : '') + '>' +
      '<b>' + esc(w.word) + '</b> <span>' + esc(w.label) + '</span> <span class="meta">' + (off(w) ? 'part off' : w.since ? 'since ' + esc(C.hm(w.since)) : '') + '</span></button></li>').join('');
    const n = countWaiting(list);
    return '<h2 class="vh" id="h-puddle">Waiting on you</h2>' + note(s, ['attention.changes'], C) +
      (list.length ? '<ul class="ripples">' + items + '</ul>' : '') + (n || isDark(s, ['attention.changes']) ? '' : '<p class="calm">Nothing waits on you. The street is dark.</p>');
  }

  function renderHeader(s, list, ui, C) {
    const n = countWaiting(list);
    const name = s.person && isStr(s.person.name) ? s.person.name.toLowerCase() : 'your street';
    return '<div class="streetplate"><h1>' + esc(name) + '</h1>' +
      '<p><span class="count">' + (n ? n + ' waiting on you' : isDark(s, ['attention.changes']) ? 'what waits is not read' : 'nothing waiting') + '</span> · ' + esc(C.long(ui.now)) + ', ' + esc(C.hm(ui.now)) + '</p></div>' +
      '<button class="btn btn--icon fuse-btn" data-act="fusebox" aria-controls="fusebox" aria-expanded="' + !!ui.fuse + '">' + icon('breaker') + '<span>Parts</span></button>';
  }

  function renderFusebox(s, ui) {
    const o = order(s.prefs);
    const rows = o.map((id, i) => {
      const on = isOn(s.prefs, id);
      const label = PARTS[id].label;
      return '<li class="breaker' + (on ? ' breaker--on' : '') + '"><button class="switch" role="switch" aria-checked="' + on + '" data-act="part-toggle" data-part="' + id + '"><span class="switch__lever" aria-hidden="true"></span><span>' + esc(label) + '</span></button>' +
        '<span class="moves"><button class="btn btn--sq" data-act="part-move" data-part="' + id + '" data-dir="-1" aria-label="Move ' + esc(label) + ' earlier"' + (i === 0 ? ' disabled' : '') + '>‹</button>' +
        '<button class="btn btn--sq" data-act="part-move" data-part="' + id + '" data-dir="1" aria-label="Move ' + esc(label) + ' later"' + (i === o.length - 1 ? ' disabled' : '') + '>›</button></span></li>';
    }).join('');
    return '<div class="fusebox__in"><h2 id="h-fuse">' + tube('Parts') + '</h2><p class="meta">Flip a breaker to light or cut a part. Arrows move it along the street.</p>' +
      (ui.note ? '<p class="note" role="status">' + esc(ui.note) + '</p>' : '') +
      '<ul class="breakers">' + rows + '</ul><button class="btn" data-act="fusebox">Done</button></div>';
  }

  function renderStreet(s, ui) {
    const C = clock(s);
    const list = waiting(s, ui);
    const lit = litTable(list);
    const o = order(s.prefs).filter((id) => isOn(s.prefs, id));
    const part = (id) => '<section class="part part--' + id + ' part--' + PARTS[id].size + '" data-part="' + id + '" data-line="' + lineOf(s, PARTS[id].streams).state + '" aria-labelledby="h-' + id + '">' + RENDER[id](s, lit, ui, C) + '</section>';
    const zone = (z) => {
      let out = '', stack = [];
      const flush = () => { if (stack.length) out += '<div class="stack">' + stack.join('') + '</div>'; stack = []; };
      for (const id of o.filter((p) => PARTS[p].zone === z)) {
        if (PARTS[id].size === 'half') { stack.push(part(id)); if (stack.length === 2) flush(); } else { flush(); out += part(id); }
      }
      flush();
      return out;
    };
    return { header: renderHeader(s, list, ui, C), wall: zone('wall'), level: zone('level'), puddle: renderPuddle(s, list, ui, C), list, lit, C };
  }

  root.Night = { PARTS, ORDER, KINDS, HOLD, OPEN, EMPTY, hear, opening, refused, isOn, order, flipDoc, moveDoc, waiting, litTable, renderStreet, renderFusebox, clock, compName, versionless, time, text, words, isItem, esc, weatherOf, feedOf, sysOf, storage, systemLines, chase };
})(this);

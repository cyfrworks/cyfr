/* The night street: what waits on the person is the only neon that burns.
 *
 * This file holds the state the streams fold into and the renderers, which
 * are pure functions from that state to markup; street.js feeds it and
 * draws. Every value a stream carries is set as escaped text. */
(function (root) {
  'use strict';

  // ---------- the parts along the street, each a widget of the preferences ----------
  // zone: the wall above or the street level below; size: how it stands on the
  // wall; off: dark until the person lights it. The street reads at most
  // STREAMS at once (each open stream holds one of the six connections a
  // browser keeps to a host over plain HTTP), so the parts that start lit
  // read five, and the feeds, the crew and the vault start dark.
  const PARTS = {
    threads: { label: 'Threads', zone: 'wall', size: 'tall', streams: ['threads.changes'] },
    board: { label: 'Schedules and runs', zone: 'wall', size: 'tall', streams: ['schedules.changes', 'runs.changes'] },
    weather: { label: 'Weather', zone: 'wall', size: 'half', streams: ['feed:weather'], off: true },
    crew: { label: 'Crew at work', zone: 'wall', size: 'half', streams: ['activity.changes'], off: true },
    vpn: { label: 'VPN', zone: 'wall', size: 'tall', streams: ['feed:vpn'], off: true },
    vault: { label: 'Vault', zone: 'wall', size: 'tall', streams: ['vault.changes'], off: true },
    cyfr: { label: 'CYFR', zone: 'level', size: 'box', streams: ['components.changes'] },
    apps: { label: 'Apps', zone: 'level', size: 'row', streams: ['components.changes'] },
    files: { label: 'Files', zone: 'level', size: 'box', streams: [] },
  };
  const ORDER = Object.keys(PARTS);
  const STREAMS = 5;

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
    runs: [],
    schedules: new Map(),
    activity: new Map(),
    components: new Map(),
    vault: new Map(),
    feeds: { weather: null, vpn: null },
    installed: [],
    refusals: {},
    opened: {},
    prefs: {},
    person: null,
    appearance: null,
  });

  // ---------- folding a stream's item into the state ----------
  const isItem = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
  const text = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');
  const MAX_RUNS = 20;

  function fold(s, stream, item, heardAt) {
    if (!isItem(item)) return;
    if (stream === 'attention.changes') {
      const id = text(item.id);
      if (!id) return;
      if (item.kind === 'removed') s.attention.delete(id);
      else if (KINDS[item.kind]) s.attention.set(id, item);
    } else if (stream === 'threads.changes') {
      const id = text(item.id);
      if (!id) return;
      if (item.kind === 'removed') s.threads.delete(id); else s.threads.set(id, item);
    } else if (stream === 'schedules.changes') {
      const id = text(item.schedule_id);
      if (!id) return;
      if (item.kind === 'removed') s.schedules.delete(id); else s.schedules.set(id, item);
    } else if (stream === 'runs.changes') {
      const id = text(item.execution_id);
      if (!id || item.parent_execution_id) return;
      const before = s.runs.find((r) => r.item.execution_id === id);
      // A start that races the refresh never undoes the outcome already shown.
      if (before && before.item.kind !== 'started' && item.kind === 'started') return;
      const at = item.refresh === true ? (before ? before.at : null) : heardAt;
      s.runs = [{ item, at }].concat(s.runs.filter((r) => r.item.execution_id !== id)).slice(0, MAX_RUNS);
    } else if (stream === 'activity.changes') {
      const id = text(item.id);
      if (!id) return;
      if (item.kind === 'ended') s.activity.delete(id); else s.activity.set(id, item);
    } else if (stream === 'components.changes') {
      const ref = text(item.ref);
      if (!ref) return;
      if (item.kind === 'removed') s.components.delete(ref); else s.components.set(ref, item);
    } else if (stream === 'vault.changes') {
      const name = text(item.name);
      if (!name) return;
      if (item.kind === 'removed') s.vault.delete(name); else s.vault.set(name, item);
    } else if (stream.startsWith('feed:')) {
      const feed = stream.slice(5);
      const was = s.feeds[feed];
      if (!was || !(Number(item.revision) <= Number(was.revision))) s.feeds[feed] = item;
    }
  }

  // A reopened stream's refresh holds every item there is: what it did not
  // deliver was removed while it was closed.
  function refreshed(s, stream, seen) {
    const key = { 'attention.changes': 'attention', 'threads.changes': 'threads', 'schedules.changes': 'schedules', 'activity.changes': 'activity', 'components.changes': 'components', 'vault.changes': 'vault' }[stream];
    if (!key) return;
    for (const id of [...s[key].keys()]) if (!seen.has(id)) s[key].delete(id);
  }
  const keyOf = (stream, item) => {
    if (!isItem(item)) return '';
    if (stream === 'schedules.changes') return text(item.schedule_id);
    if (stream === 'components.changes') return text(item.ref);
    if (stream === 'vault.changes') return text(item.name);
    return text(item.id);
  };

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
  // The streams the parts that are on read, what waits first and then the
  // parts in their order along the street: the first STREAMS are opened,
  // and the rest are held until a part is cut.
  function wantedStreams(prefs) {
    const want = ['attention.changes'];
    for (const id of order(prefs)) if (isOn(prefs, id)) for (const st of PARTS[id].streams) if (!want.includes(st)) want.push(st);
    return { open: want.slice(0, STREAMS), held: want.slice(STREAMS) };
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
  const time = (v) => { const t = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isNaN(t) ? null : t; };
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
      out.push({ id: 'a:' + text(a.id), kind: a.kind, target, label: a.kind === 'failed_run' ? compName(a.label || a.id) : text(a.label), since: time(a.since), page: d.kind === 'page' ? text(d.page) : null, item: a, word: k.word, hue: k.hue, light: k.light });
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
  const refusal = (s, stream) => s.refusals[stream] ? '<p class="refused">' + esc(s.refusals[stream]) + '</p>' : '';

  // ---------- parts ----------
  function renderThreads(s, lit, ui, C) {
    const list = [...s.threads.values()].sort((a, b) => (time(b.last_activity) || 0) - (time(a.last_activity) || 0)).slice(0, 6);
    const rows = list.map((t, i) => {
      const L = lit.get('thread:' + text(t.id));
      const people = Array.isArray(t.people) ? t.people.length : 0;
      const who = t.kind === 'own' ? 'with AQUA' : people === 2 ? 'pair' : people + ' people';
      const last = time(t.last_activity);
      return '<li class="hang" style="--tilt:' + ([-1.2, 0.9, -0.6, 1.3, -0.9, 0.7][i % 6]) + 'deg">' +
        '<button class="sign plaque plaque--' + (t.kind === 'own' ? 'own' : 'shared') + '" data-target="thread:' + esc(t.id) + '"' + lightAttrs(L) + '>' +
        '<span class="plaque__title">' + tube(text(t.title) || 'Untitled', L && L.light) + '</span>' +
        '<span class="meta">' + esc(who) + (last ? ' · ' + esc(C.when(last, ui.now)) : '') + (t.waits_on_you && !L ? ' · waits on you' : '') + tag(L) + '</span></button></li>';
    }).join('');
    const empty = !list.length ? '<li class="hang"><span class="sign plaque plaque--shared plaque--empty"><span class="plaque__title tube">No threads yet</span><span class="meta">a chat with AQUA hangs here</span></span></li>' : '';
    return '<h2 class="vh" id="h-threads">Threads</h2>' + refusal(s, 'threads.changes') + '<ul class="plaques">' + rows + empty + '</ul>';
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
    // A failure that waits on the person never scrolls off the board; the newest others fill the rest.
    const failedRefs = new Set([...lit.keys()].filter((k) => k.startsWith('failed:')).map((k) => k.slice(7)));
    const shownFor = new Set();
    const rows = [];
    for (const r of s.runs) {
      const ref = text(r.item.reference);
      const L = r.item.kind === 'failed' && failedRefs.has(ref) && !shownFor.has(ref) ? lit.get('failed:' + ref) : null;
      if (L) shownFor.add(ref);
      rows.push({ r, L });
    }
    for (const ref of failedRefs) if (!shownFor.has(ref)) rows.push({ r: null, L: lit.get('failed:' + ref), ref });
    // At most four rows: the failures that wait first, then the newest others.
    const litRows = rows.filter((x) => x.L);
    const keep = litRows.slice(0, 4).concat(rows.filter((x) => !x.L)).slice(0, 4);
    const more = litRows.length - keep.filter((x) => x.L).length;
    // A short screen shows three rows; its line counts from the third.
    const moreShort = litRows.length - Math.min(3, keep.filter((x) => x.L).length);
    const ran = rows.filter((x) => keep.includes(x)).map(({ r, L, ref }, i) => {
      const item = r ? r.item : null;
      const reference = item ? text(item.reference) : ref;
      const name = compName(reference);
      const kind = item ? item.kind : 'failed';
      const err = item && isItem(item.error) ? item.error : null;
      const out = kind === 'failed' ? (err ? words(err.class) + ' · ' + words(err.cause) : 'failed') : kind === 'started' ? 'running' : kind === 'cancelled' ? 'cancelled' : typeof item.duration_ms === 'number' ? (item.duration_ms / 1000).toFixed(1) + ' s' : 'done';
      const at = r && r.at ? C.hm(r.at) : L && L.since ? C.hm(L.since) : '--:--';
      const target = L ? 'failed:' + reference : 'run:' + text(item.execution_id);
      return '<li' + (i === 3 ? ' class="row--fourth"' : '') + '><button class="row row--ran' + (kind === 'started' ? ' row--working' : '') + '" data-target="' + esc(target) + '"' + lightAttrs(L) + '>' +
        '<span class="dot when">' + esc(at) + '</span>' +
        '<span class="dot what">' + (L ? tube(name, L.light) : esc(name)) + '</span>' +
        '<span class="row__meta">' + (L ? tube(out, 'burn') : esc(out)) + '</span>' +
        (kind === 'completed' ? lamp('ok', 'finished') : kind === 'started' ? lamp('work', 'running') : kind === 'cancelled' ? lamp('off', 'cancelled') : lamp('bad', 'failed')) + '</button></li>';
    }).join('');
    const none = (t) => '<li><p class="row row--none">' + esc(t) + '</p></li>';
    return '<div class="sign board"><h2 id="h-board" class="board__head">' + tube('Schedules') + '</h2>' + refusal(s, 'schedules.changes') +
      '<h3 class="board__sub">Next</h3><ul class="rows">' + (next || none('Nothing is scheduled.')) + '</ul>' + refusal(s, 'runs.changes') +
      '<h3 class="board__sub">Lately</h3><ul class="rows">' + (ran || none('No runs yet.')) + '</ul>' +
      (more > 0 ? '<p class="board__more board__more--tall">and ' + more + ' more failed, in the puddle below</p>' : '') +
      (moreShort > 0 ? '<p class="board__more board__more--short">and ' + moreShort + ' more failed, in the puddle below</p>' : '') + '</div>';
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

  function renderWeather(s, lit, ui, C) {
    const f = s.feeds.weather;
    if (!f) return '<div class="sign roofsign roofsign--dark">' + (s.refusals['feed:weather'] ? '<h2 id="h-weather" class="unbound__head">' + tube('Weather') + '</h2>' + refusal(s, 'feed:weather') : unbound('weather', 'Weather', 'No weather feed is bound yet.')) + '</div>';
    const w = weatherOf(f);
    const at = time(f.at);
    const hi = w.hours.length ? Math.max(...w.hours) : 0, lo = w.hours.length ? Math.min(...w.hours) - 3 : 0;
    const bars = w.hours.map((c, i) => '<li style="--h:' + Math.round(((c - lo) / Math.max(1, hi - lo)) * 100) + '%" aria-label="in ' + (i + 1) + ' h, ' + c + ' degrees"><span class="bar"></span><b>' + esc(Math.round(c)) + '°</b></li>').join('');
    const refresh = Array.isArray(f.actions) ? f.actions.find((a) => isItem(a) && /refresh|update|reload/i.test(text(a.name))) || f.actions[0] : null;
    return '<div class="sign roofsign' + (ui.working.weather ? ' is-working' : '') + '" data-target="feed:weather">' +
      '<h2 id="h-weather" class="vh">Weather</h2>' +
      '<button class="big" data-target="feed:weather" aria-label="Weather' + (w.place ? ' in ' + esc(w.place) : '') + '">' + tube(w.temp !== undefined ? Math.round(w.temp) + '°' : '—') + '</button>' +
      '<span class="roofsign__where"><b>' + esc(w.place) + '</b>' + (w.sky ? '<span>' + esc(w.sky) + '</span>' : '') + (w.wind !== undefined ? '<span>wind ' + esc(w.wind) + ' km/h</span>' : '') + '<span class="meta">' + (ui.working.weather ? 'refreshing…' : at ? 'updated ' + esc(C.hm(at)) : '') + '</span></span>' +
      '<ol class="hours" aria-label="Next hours">' + bars + '</ol>' +
      (refresh && isItem(refresh) && isStr(refresh.name) ? '<button class="btn btn--round" data-act="feed-press" data-feed="weather" data-binding="' + esc(f.binding) + '" data-action="' + esc(refresh.name) + '" aria-label="' + esc(text(refresh.label) || 'Refresh') + '">' + icon('refresh') + '</button>' : '') +
      chase() + '</div>';
  }

  function renderCrew(s, lit, ui, C) {
    const jobs = [...s.activity.values()].sort((a, b) => (time(a.since) || 0) - (time(b.since) || 0));
    if (!jobs.length) return '<button class="sign crewsign" data-target="crew"><span class="crewsign__head" id="h-crew">' + tube('Crew') + '</span><span class="meta">' + (s.refusals['activity.changes'] ? esc(s.refusals['activity.changes']) : 'No one is at work.') + '</span></button>';
    const j = jobs[0], at = time(j.since);
    return '<button class="sign crewsign is-working" data-target="crew">' +
      '<span class="vh" id="h-crew">Crew at work</span>' +
      '<span class="crewsign__head">' + tube(text(j.member)) + '</span>' +
      '<span class="crewsign__title">' + esc(words(j.status) || 'working') + (jobs.length > 1 ? ' · ' + (jobs.length - 1) + ' more at work' : '') + '</span>' +
      '<span class="meta">' + (j.asked_by ? 'for ' + esc(j.asked_by) : '') + (at ? ' · since ' + esc(C.hm(at)) + ' · ' + esc(since(at, ui.now)) : '') + '</span>' +
      chase() + '</button>';
  }

  function renderVpn(s, lit, ui, C) {
    const f = s.feeds.vpn;
    if (!f) return '<div class="mast mast--dark"><div class="sign mastbox">' + (s.refusals['feed:vpn'] ? '<h2 id="h-vpn" class="unbound__head">' + tube('VPN') + '</h2>' + refusal(s, 'feed:vpn') : unbound('vpn', 'VPN', 'No VPN feed is bound yet.')) + '</div></div>';
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
      '<p class="meta">' + (down !== undefined ? esc(down) + ' Mb/s down' : at ? 'updated ' + esc(C.hm(at)) : '&nbsp;') + '</p><div class="mastbox__acts">' + feedActions(f) + '</div>' + chase() + '</div></div>';
  }

  function renderVault(s) {
    const rows = [...s.vault.values()].sort((a, b) => (a.status === 'fine') - (b.status === 'fine') || text(a.name).localeCompare(text(b.name))).slice(0, 6).map((v) => {
      const fine = v.status === 'fine';
      const st = fine ? 'fine' : 'needs re-authorisation';
      return '<li><button class="row row--vault" data-target="vault:' + esc(v.name) + '">' + icon('lock') + '<span class="what">' + esc(v.name) + '</span><span class="row__meta">' + esc(words(v.type)) + ' · ' + esc(st) + '</span>' + lamp(fine ? 'ok' : 'bad', st) + '</button></li>';
    }).join('');
    return '<div class="sign strongbox"><h2 id="h-vault" class="strongbox__head">' + tube('Vault') + '</h2>' + refusal(s, 'vault.changes') + '<ul class="rows">' + (rows || '<li><p class="row row--none">The vault is empty.</p></li>') + '</ul><p class="meta">Names and status only.</p></div>';
  }

  function renderApps(s, lit) {
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
    return '<h2 class="vh" id="h-apps">Apps</h2><ul class="shops">' + (shops || '<li class="shop shop--none"><p class="meta">No apps yet. Ask AQUA to make you one.</p></li>') + '</ul>';
  }

  function renderFiles(s, lit, ui, C) {
    const offers = [...s.attention.values()].filter((a) => a.kind === 'file_offer').slice(0, 4).map((o) => {
      const L = lit.get('offer:' + text(o.id));
      const at = time(o.since);
      return '<li><button class="sign cubby cubby--offer" data-target="offer:' + esc(o.id) + '"' + lightAttrs(L) + '>' + icon('file') +
        '<span class="cubby__name">' + (L ? tube(text(o.label), L.light) : esc(o.label)) + '</span><span class="meta">offered' + (at ? ' · ' + esc(C.hm(at)) : '') + '</span></button></li>';
    }).join('');
    const empty = '<li><button class="cubby cubby--empty" data-act="settings" data-page="files">' + icon('file') + '<span class="cubby__name">Files</span><span class="meta">nothing offered</span></button></li>';
    return '<div class="locker"><h2 id="h-files" class="locker__head">' + tube('Files') + '</h2><ul class="cubbies">' + (offers || empty) + '</ul></div>';
  }

  function renderCyfr(s, lit) {
    const L = lit.get('cyfr');
    const comps = [...s.components.values()];
    const updates = comps.filter((c) => c.update_available === true).length;
    const grants = comps.filter((c) => c.grant_current === false).length;
    const crew = s.activity.size;
    const refused = s.refusals['components.changes'];
    return '<button class="sign junction" data-target="cyfr"' + lightAttrs(L) + '>' +
      '<span class="junction__head" id="h-cyfr">' + tube('CYFR') + tag(L) + '</span>' +
      (refused ? '<span class="jl jl--refused">' + esc(refused) + '</span>' :
        '<span class="jl">' + lamp(comps.length ? 'ok' : 'off') + esc(comps.length) + ' installed</span>' +
        '<span class="jl">' + lamp(updates ? 'warn' : 'ok') + (updates ? esc(updates) + ' update' + (updates > 1 ? 's' : '') : 'up to date') + '</span>' +
        '<span class="jl">' + lamp(grants ? 'warn' : 'ok') + (grants ? esc(grants) + ' to grant' : 'all granted') + '</span>') +
      (isOn(s.prefs, 'crew') ? '<span class="jl">' + lamp(crew ? 'work' : 'off') + (crew ? 'crew ' + esc(crew) + ' at work' : 'crew at rest') + '</span>' : '') +
      '</button>';
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
    return '<h2 class="vh" id="h-puddle">Waiting on you</h2>' + refusal(s, 'attention.changes') +
      (list.length ? '<ul class="ripples">' + items + '</ul>' : '') + (n ? '' : '<p class="calm">Nothing waits on you. The street is dark.</p>');
  }

  function renderHeader(s, list, ui, C) {
    const n = countWaiting(list);
    const name = s.person && isStr(s.person.name) ? s.person.name.toLowerCase() : 'your street';
    return '<div class="streetplate"><h1>' + esc(name) + '</h1>' +
      '<p><span class="count">' + (n ? n + ' waiting on you' : 'nothing waiting') + '</span> · ' + esc(C.long(ui.now)) + ', ' + esc(C.hm(ui.now)) + '</p></div>' +
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
    const part = (id) => '<section class="part part--' + id + ' part--' + PARTS[id].size + '" data-part="' + id + '" aria-labelledby="h-' + id + '">' + RENDER[id](s, lit, ui, C) + '</section>';
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

  root.Night = { PARTS, ORDER, STREAMS, KINDS, EMPTY, fold, refreshed, keyOf, isOn, order, flipDoc, moveDoc, wantedStreams, waiting, litTable, renderStreet, renderFusebox, clock, compName, versionless, time, text, words, isItem, esc, weatherOf };
})(this);

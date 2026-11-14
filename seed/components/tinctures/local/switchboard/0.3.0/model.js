/* The switchboard's state: what the shell told the desktop at its open and
   since (installed apps, posture, covered, live or frozen, the desktop's
   preferences, appearance and person), and what each declared stream has
   said, held by the delivery contract `canvas.catalog` documents. Nothing
   here draws; board.js and plain.js read it through `SB` and are told when
   it changed. */
(function () {
  'use strict';

  // The streams the page reads, each named in the manifest's `data`, and
  // the feeds it reads by name, each in its `feeds`. Every one rides the
  // frame's one stream connection, so all are open at once, whatever part
  // is on.
  const DATA = [
    'attention.changes', 'threads.changes', 'components.changes', 'runs.changes', 'schedules.changes',
    'vault.changes', 'activity.changes', 'files.changes', 'system.changes',
  ];
  const FEEDS = ['weather', 'vpn'];
  const STREAMS = [...DATA, ...FEEDS.map((name) => `feed:${name}`)];
  // The controls the manifest declares.
  const PAUSE = 'pause-schedule';
  const RESUME = 'resume-schedule';
  const RETRY = 'retry-run';
  const MAX_RUNS = 20;
  // Pauses before opening again a stream whose open had no answer.
  const RETRY_MS = [2000, 5000, 15000, 60000];
  // The parts that wait in the spares until the person fits one.
  const SPARE = ['files'];

  const isItem = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
  const text = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');

  // How each stream names its items and how one leaves: the catalog's `key`
  // and `removal`, and the `reread` kinds that only say a fresh picture
  // follows. `kind` is what the page is told changed.
  const RULES = {
    'attention.changes': { key: (i) => i.id, removal: 'removed', kind: 'attention' },
    'threads.changes': { key: (i) => i.id, removal: 'removed', kind: 'threads' },
    // Every installed version, by its ref and version, since a removal
    // names the version it removes; a line shows a component's newest.
    'components.changes': {
      key: (i) => (typeof i.ref === 'string' ? `${i.ref}@${text(i.version)}` : null),
      removal: 'removed', reread: ['installed', 'pushed', 'changed'], kind: 'components',
    },
    'runs.changes': { key: (i) => i.execution_id, removal: null, kind: 'runs' },
    'schedules.changes': { key: (i) => i.schedule_id, removal: 'removed', kind: 'schedules' },
    'vault.changes': { key: (i) => i.name, removal: 'removed', kind: 'vault' },
    'activity.changes': { key: (i) => i.id, removal: 'ended', kind: 'activity' },
    'files.changes': { key: (i) => i.id, removal: 'removed', kind: 'files' },
    // One item: how the person's CYFR stands.
    'system.changes': { key: () => 'system', removal: null, kind: 'system' },
  };
  const FEED_RULE = { key: (i) => i.binding, removal: null, kind: 'feeds' };
  const rule = (key) => RULES[key] || FEED_RULE;

  const state = {
    installed: [],
    posture: null,
    covered: [],
    live: true,
    prefs: { document: {}, revision: null },
    appearance: { mode: 'light', accent: null, locale: undefined, time_zone: undefined, safe_areas: null },
    person: null,
  };

  // A picture: each item by its key with the revision it came with, and the
  // revision each removed item left with, so an older change cannot bring
  // it back.
  const hold = () => ({ items: new Map(), gone: new Map() });
  // Each stream as the page holds it: `held`, the picture it shows;
  // `picture`, one gathered after an open or a `resync`, which replaces
  // `held` at its `snapshot`; and how it stands: `opening`, `live`, `stale`
  // (as of `at`), `unavailable` (opened again at `retryAt`), `denied`, or
  // `refused` at an open (`code`, the refusal's class).
  const streams = Object.fromEntries(STREAMS.map((key) => [key, {
    held: hold(), picture: null, state: 'opening', at: null, retryAt: null, code: null, handle: null, opens: 0, timer: 0,
  }]));
  // The calls a live removal cleared since the board last looked: a call a
  // fresh picture no longer names leaves without being said to clear.
  const cleared = new Set();

  const listeners = new Set();
  const pending = new Set();
  let queued = false;
  // Many events arrive together (a picture): the page is told once per frame.
  function changed(what) {
    pending.add(what);
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      const kinds = new Set(pending);
      pending.clear();
      for (const fn of listeners) fn(kinds);
    });
  }

  /* ---------- what the shell tells the desktop ---------- */

  function onInstalled(list) {
    state.installed = Array.isArray(list)
      ? list.filter((a) => isItem(a) && typeof a.ref === 'string' && typeof a.name === 'string')
        .map((a) => ({ ref: a.ref, name: a.name, icon: typeof a.icon === 'string' ? a.icon : null, open: a.open === true }))
      : [];
    changed('installed');
  }
  function onCovered(rects) {
    state.covered = Array.isArray(rects)
      ? rects.filter((r) => isItem(r) && ['x', 'y', 'width', 'height'].every((k) => Number.isFinite(r[k])))
      : [];
    changed('covered');
  }
  function onPosture(p) {
    if (p === 'hand' || p === 'desk') { state.posture = p; changed('posture'); }
  }
  function onState(s) {
    if (s === 'live' || s === 'frozen') { state.live = s === 'live'; changed('state'); }
  }
  function onDesktop(value) {
    if (!isItem(value)) return;
    if (isItem(value.prefs) && isItem(value.prefs.document)) {
      state.prefs = { document: value.prefs.document, revision: value.prefs.revision ?? null };
    }
    if (isItem(value.appearance)) {
      const a = value.appearance;
      state.appearance = {
        mode: a.mode === 'dark' ? 'dark' : 'light',
        accent: typeof a.accent === 'string' ? a.accent : null,
        locale: typeof a.locale === 'string' && a.locale ? a.locale : undefined,
        time_zone: typeof a.time_zone === 'string' && a.time_zone ? a.time_zone : undefined,
        safe_areas: isItem(a.safe_areas) ? a.safe_areas : null,
      };
    }
    state.person = isItem(value.person) && typeof value.person.name === 'string' && value.person.name ? value.person.name : null;
    changed('desktop');
  }

  /* ---------- holding each stream by the delivery contract ---------- */

  const startOf = (h) => text(h.item.started_at);
  // The runs stream names the athanor's 20 newest: the page holds no more.
  function cap(into) {
    while (into.items.size > MAX_RUNS) {
      let oldest = null;
      for (const [id, h] of into.items) if (oldest === null || startOf(h) < startOf(into.items.get(oldest))) oldest = id;
      into.items.delete(oldest);
    }
  }

  // Takes one change into `into`: per item the highest revision heard wins,
  // and an equal one is the same change heard twice. Answers whether it
  // changed anything.
  function take(key, into, item, revision) {
    const r = rule(key);
    // A reread kind outside a picture only says a fresh picture follows.
    if (r.reread && r.reread.includes(item.kind) && item.refresh !== true) return false;
    const id = r.key(item);
    if (typeof id !== 'string' || id === '') return false;
    const held = into.items.get(id);
    const last = held ? held.revision : into.gone.get(id);
    if (Number.isInteger(last) && Number.isInteger(revision) && revision <= last) return false;
    // A finished run keeps its outcome against a start that raced it.
    if (key === 'runs.changes' && held && held.item.kind !== 'started' && item.kind === 'started') return false;
    if (r.removal && item.kind === r.removal) {
      into.items.delete(id);
      into.gone.set(id, revision);
    } else {
      into.items.set(id, { item, revision });
      if (key === 'runs.changes') cap(into);
    }
    return true;
  }

  // One event of the stream `key` (`cyfr.stream`'s handler).
  function hear(key, ev) {
    const s = streams[key];
    switch (ev.event) {
      case 'resync':
        s.picture = hold();
        return;
      case 'snapshot':
        // The gathered picture is whole: what it does not name is gone.
        if (s.picture) { s.held = s.picture; s.picture = null; }
        Object.assign(s, { state: 'live', at: null, retryAt: null, code: null });
        break;
      case 'stale':
        Object.assign(s, { state: 'stale', at: ev.at });
        break;
      case 'unavailable':
        Object.assign(s, { state: 'unavailable', retryAt: isItem(ev.data) ? ev.data.retry_at : null });
        break;
      case 'denied':
        Object.assign(s, { state: 'denied', held: hold(), picture: null });
        break;
      default: {
        if (ev.event !== (key.startsWith('feed:') ? 'feed.results' : key) || !isItem(ev.data)) return;
        const live = s.picture === null;
        const revision = Number.isInteger(ev.revision) ? ev.revision : ev.data.revision;
        if (!take(key, s.picture || s.held, ev.data, revision)) return;
        if (live && key === 'attention.changes' && ev.data.kind === 'removed') cleared.add(ev.data.id);
      }
    }
    changed(rule(key).kind);
  }

  /* ---------- opening each stream ---------- */

  let api = null;
  // Opens the stream `key`; resolves once the open has its answer. The SDK
  // opens an opened stream again itself after a lost connection; the page
  // opens it again only when its open had no answer (after a pause), and
  // when the endpoint ended it with no refusal.
  function open(key, attempt = 0) {
    const s = streams[key];
    const feed = key.startsWith('feed:') ? key.slice(5) : null;
    const n = ++s.opens;
    s.picture = hold();
    return api.stream(feed ? 'feed.results' : key, feed, (ev) => { if (n === s.opens) hear(key, ev); }).then((handle) => {
      s.handle = handle;
      handle.closed.then(() => {
        if (s.handle !== handle || handle.state !== 'ended') return;
        s.handle = null;
        s.timer = setTimeout(() => open(key), RETRY_MS[0]);
      }, () => {
        // Broken for good: the endpoint closed the connection for what this
        // frame sent, or for a newer connection of the same frame.
        if (s.handle !== handle) return;
        Object.assign(s, { state: 'refused', code: 'ended', held: hold(), picture: null });
        changed(rule(key).kind);
      });
    }, (error) => {
      const code = error && typeof error.code === 'string' ? error.code : 'unavailable';
      if (code === 'unavailable') {
        const wait = RETRY_MS[Math.min(attempt, RETRY_MS.length - 1)];
        Object.assign(s, { state: 'unavailable', retryAt: new Date(Date.now() + wait).toISOString() });
        s.timer = setTimeout(() => open(key, attempt + 1), wait);
      } else {
        Object.assign(s, { state: 'refused', code, held: hold(), picture: null });
      }
      changed(rule(key).kind);
    });
  }

  // Hears the shell, opens every declared stream, and calls `ready()` once
  // each first open has its answer, or after a few seconds, whichever is
  // first: the board is drawn by then either way.
  function start(sdk, onReady) {
    sdk.on('installed', onInstalled);
    sdk.on('covered', onCovered);
    sdk.on('posture', onPosture);
    sdk.on('state', onState);
    sdk.on('desktop', onDesktop);
    if (sdk.desktop) onDesktop(sdk.desktop);
    api = sdk;
    const first = STREAMS.map((key) => open(key));
    let told = false;
    const tell = () => { if (!told) { told = true; onReady(); } };
    Promise.allSettled(first).then(tell);
    setTimeout(tell, 4000);
  }

  /* ---------- reading the state ---------- */

  // Whether a part is on in `doc` (the preferences document): as its entry
  // says, else on unless it waits in the spares.
  function partOn(part, doc = state.prefs.document) {
    const entry = isItem(doc) && isItem(doc.widgets) ? doc.widgets[part] : null;
    if (isItem(entry) && typeof entry.on === 'boolean') return entry.on;
    return !SPARE.includes(part);
  }

  const items = (key) => [...streams[key].held.items.values()].map((h) => h.item);
  // "catalyst:local.openai:1.4.1" without its version.
  function componentRef(reference) {
    const parts = text(reference).split(':');
    return parts.length >= 3 ? `${parts[0]}:${parts[1]}` : text(reference);
  }
  // "catalyst:local.openai" as a person reads it: "openai".
  function componentName(ref) {
    const named = componentRef(ref).split(':')[1] || '';
    return named.includes('.') ? named.slice(named.indexOf('.') + 1) : named;
  }
  function newer(a, b) {
    const pa = text(a).split('.').map(Number), pb = text(b).split('.').map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const x = pa[i] || 0, y = pb[i] || 0;
      if (x !== y) return x > y;
    }
    return false;
  }
  // Each installed component's newest version, by its versionless ref.
  function components() {
    const by = new Map();
    for (const item of items('components.changes')) {
      const ref = text(item.ref);
      const held = by.get(ref);
      if (!held || newer(item.version, held.version)) by.set(ref, item);
    }
    return by;
  }
  // The held runs, the latest start first.
  function runs() {
    return [...streams['runs.changes'].held.items.values()]
      .sort((a, b) => startOf(b).localeCompare(startOf(a)) || (b.revision || 0) - (a.revision || 0))
      .map((h) => h.item);
  }
  // A feed's latest result: the one heard last on its subscription.
  function feed(name) {
    let best = null;
    for (const h of streams[`feed:${name}`].held.items.values()) if (!best || (h.revision || 0) > (best.revision || 0)) best = h;
    return best ? best.item : null;
  }

  window.SB = {
    state, STREAMS, FEEDS, PAUSE, RESUME, RETRY,
    start,
    subscribe(fn) { listeners.add(fn); },
    partOn,
    // How the stream `key` stands: `{state, at, retryAt, code}`.
    status(key) { const s = streams[key]; return { state: s.state, at: s.at, retryAt: s.retryAt, code: s.code }; },
    // The item the stream `key` holds under `id`, or null.
    get(key, id) { const h = streams[key].held.items.get(id); return h ? h.item : null; },
    // The calls a live removal cleared since the last look, once.
    takeCleared() { const out = [...cleared]; cleared.clear(); return out; },
    attention: () => items('attention.changes'),
    threads: () => items('threads.changes'),
    schedules: () => items('schedules.changes'),
    vault: () => items('vault.changes'),
    activity: () => items('activity.changes'),
    files: () => items('files.changes'),
    system: () => items('system.changes')[0] || null,
    runs, feed, components,
    componentRef, componentName, text, isItem,
  };
})();

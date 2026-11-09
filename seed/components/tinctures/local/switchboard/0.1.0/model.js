/* The switchboard's state: what the shell told the desktop at its open and
   since (installed apps, posture, covered, live or frozen, the desktop's
   preferences, appearance and person), and what each declared stream has
   said, current state first and then changes. Nothing here draws; board.js
   and plain.js read `SB.state` and are told when it changed. */
(function () {
  'use strict';

  // The feeds the page reads, each named in the manifest's `feeds`.
  const FEEDS = ['weather'];
  // The controls the manifest declares, each picking a schedule's id.
  const PAUSE = 'pause-schedule';
  const RESUME = 'resume-schedule';
  const MAX_RUNS = 20;
  // Pauses before opening an ended stream again, growing while opens fail.
  const RETRY_MS = [2000, 5000, 15000, 60000];

  const state = {
    installed: [],
    posture: null,
    covered: [],
    live: true,
    prefs: { document: {}, revision: null },
    appearance: { mode: 'light', accent: null, locale: undefined, time_zone: undefined, safe_areas: null },
    person: null,
    attention: new Map(),
    threads: new Map(),
    // By `ref@version`: a component's newest version is the one a line shows.
    components: new Map(),
    // One entry per run, the latest change first.
    runs: [],
    schedules: new Map(),
    vault: new Map(),
    activity: new Map(),
    feeds: Object.fromEntries(FEEDS.map((name) => [name, null])),
    // A stream refused at its first open, and the sentence it was refused with.
    refusals: {},
  };

  const listeners = new Set();
  const pending = new Set();
  let queued = false;
  // Many events arrive together (a refresh): the page is told once per frame.
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

  const isItem = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
  const text = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');

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

  /* ---------- what the streams say ---------- */

  // Each keyed item remembers the open that last delivered it, so a reopen's
  // refresh, which holds everything there is, drops what an earlier open
  // delivered and this one did not.
  function keep(map, key, item, open, removed) {
    if (typeof key !== 'string' || key === '') return;
    if (removed) map.delete(key);
    else map.set(key, { item, open });
  }
  function sweep(map, open) {
    for (const [key, held] of map) if (held.open < open) map.delete(key);
  }

  function fold(stream, item, open) {
    switch (stream) {
      case 'attention.changes':
        keep(state.attention, item.id, item, open, item.kind === 'removed');
        return changed('attention');
      case 'threads.changes':
        keep(state.threads, item.id, item, open, item.kind === 'removed');
        return changed('threads');
      case 'components.changes':
        // `changed` asks the reader to open the stream again.
        if (item.kind === 'changed') { reopen('components.changes'); return; }
        keep(state.components, `${text(item.ref)}@${text(item.version)}`, item, open, item.kind === 'removed');
        return changed('components');
      case 'runs.changes':
        state.runs = keepRun(state.runs, item);
        return changed('runs');
      case 'schedules.changes':
        keep(state.schedules, item.schedule_id, item, open, item.kind === 'removed');
        return changed('schedules');
      case 'vault.changes':
        keep(state.vault, item.name, item, open, item.kind === 'removed');
        return changed('vault');
      case 'activity.changes':
        keep(state.activity, item.id, item, open, item.kind === 'ended');
        return changed('activity');
      default:
        return undefined;
    }
  }
  const SWEPT = {
    'attention.changes': 'attention', 'threads.changes': 'threads', 'components.changes': 'components',
    'schedules.changes': 'schedules', 'vault.changes': 'vault', 'activity.changes': 'activity',
  };
  function opened(stream, open) {
    const key = SWEPT[stream];
    if (key) { sweep(state[key], open); changed(key); }
  }

  // A feed's result is taken once per revision, the newest kept.
  function foldFeed(name, item) {
    const held = state.feeds[name];
    const rev = Number(item.revision);
    if (held && Number.isFinite(rev) && Number(held.revision) >= rev) return;
    state.feeds[name] = item;
    changed('feeds');
  }

  // One entry per run, the latest change first. A start published while the
  // stream opened can arrive after the refresh showed that run finished, so
  // a finished run keeps its outcome.
  function keepRun(runs, run) {
    const id = run.execution_id;
    if (typeof id !== 'string') return runs;
    const before = runs.find((r) => r.execution_id === id);
    if (before && before.kind !== 'started' && run.kind === 'started') return runs;
    return [run, ...runs.filter((r) => r.execution_id !== id)].slice(0, MAX_RUNS);
  }

  function refused(stream, error) {
    const message = error && typeof error.message === 'string' ? error.message : '';
    state.refusals[stream] = message || 'This could not be read.';
    changed('refusals');
  }

  /* ---------- keeping each stream open ---------- */

  const followers = new Map();

  // Keeps one declared stream open. Every stream ends in time (its grant has
  // a deadline, and a connection can break), so one that ends is opened
  // again after a pause and starts again with its current state. Until it
  // has opened once, a refusal is final and nothing is retried; an open the
  // endpoint gave no answer on (`unavailable`) is tried again on the same
  // pauses. `first` resolves when the first open has its answer.
  function follow(sdk, name, subject, onItem, onOpen, onRefused) {
    let stopped = false;
    let opens = 0;
    let everOpened = false;
    let current = null;
    let timer;

    async function open() {
      const n = ++opens;
      const stream = await sdk.stream(name, subject, ({ data }) => {
        if (!stopped && n === opens && isItem(data)) onItem(data, n);
      });
      if (stopped || n !== opens) { stream.close(); return; }
      everOpened = true;
      current = stream;
      onOpen(n);
      stream.closed.catch(() => {}).then(() => {
        if (current !== stream) return;
        current = null;
        retry(0);
      });
    }
    function failed(error, attempt) {
      if (stopped) return;
      // No answer, or too many open at once, is tried again.
      const unanswered = error && (error.code === 'unavailable' || error.code === 'rate_limited');
      if (!everOpened && !unanswered) onRefused(error);
      else retry(attempt);
    }
    function retry(attempt) {
      if (stopped) return;
      clearTimeout(timer);
      timer = setTimeout(() => {
        open().catch((e) => failed(e, Math.min(attempt + 1, RETRY_MS.length - 1)));
      }, RETRY_MS[attempt]);
    }
    return {
      first: open().catch((e) => failed(e, 0)),
      stop() {
        stopped = true;
        clearTimeout(timer);
        if (current) current.close();
        current = null;
      },
      // Opens the stream again now, its refresh first.
      again() {
        if (stopped) return;
        const was = current;
        current = null;
        if (was) was.close();
        clearTimeout(timer);
        open().catch((e) => failed(e, 0));
      },
    };
  }

  function reopen(stream) {
    const f = followers.get(stream);
    if (f) f.again();
  }

  // The streams the page opens, at most five at once, each only while a
  // part that reads it is on. A browser keeps six connections to one host
  // over HTTP/1.1 and each open stream holds one; and the server counts a
  // stream the page closed against the frame's eight for minutes after,
  // so the page opens a stream when a part needs it and keeps it open,
  // rather than reading streams in turn. In the order the page gives them
  // room: the lamps first.
  const ORDER = ['attention.changes', 'threads.changes', 'components.changes', 'runs.changes', 'schedules.changes', 'vault.changes', 'activity.changes', 'feed:weather'];
  const MOST = 5;
  // The parts each stream is read for. The lamps read attention on every part.
  const NEEDS = {
    'threads.changes': ['threads'],
    'components.changes': ['components', 'apps'],
    'runs.changes': ['runs', 'components'],
    'schedules.changes': ['schedules'],
    'vault.changes': ['vault'],
    'activity.changes': ['crew'],
    'feed:weather': ['weather'],
  };
  // The parts that wait in the spares until the person fits one, so the
  // board as it comes needs five streams.
  const SPARE = ['vault', 'crew', 'weather'];

  // Whether a part is on in `doc` (the preferences document): as its entry
  // says, else on unless it is one of the spares.
  function partOn(part, doc = state.prefs.document) {
    const entry = isItem(doc) && isItem(doc.widgets) ? doc.widgets[part] : null;
    if (isItem(entry) && typeof entry.on === 'boolean') return entry.on;
    return !SPARE.includes(part);
  }
  // The streams the parts that are on need, in order.
  function wanted(on = partOn) {
    return ORDER.filter((key) => !NEEDS[key] || NEEDS[key].some((part) => on(part)));
  }

  // Opens each stream a part that is on needs, up to five, and closes one
  // no part that is on needs any more.
  let api = null;
  function sync() {
    if (!api) return;
    const keep = wanted().slice(0, MOST);
    for (const [key, held] of followers) if (!keep.includes(key)) { held.stop(); followers.delete(key); }
    changed('refusals');
    for (const key of keep) {
      if (followers.has(key)) continue;
      const feed = key.startsWith('feed:') ? key.slice(5) : null;
      followers.set(key, feed
        ? follow(api, 'feed.results', feed, (item) => foldFeed(feed, item), () => {}, (error) => refused(key, error))
        : follow(api, key, null,
          (item, open) => fold(key, item, open),
          // A reopen's refresh arrives after the open: what an earlier open
          // delivered and this one did not is dropped once it has.
          (open) => setTimeout(() => opened(key, open), 2500),
          (error) => refused(key, error)));
    }
  }

  // Hears the shell, opens the streams its parts need, and calls `ready()`
  // once each stream's first open has its answer (opened, refused, or
  // unanswered and to be tried again), or after a few seconds, whichever is
  // first: the board is drawn by then either way.
  function start(sdk, onReady) {
    sdk.on('installed', onInstalled);
    sdk.on('covered', onCovered);
    sdk.on('posture', onPosture);
    sdk.on('state', onState);
    sdk.on('desktop', (value) => { onDesktop(value); sync(); });
    if (sdk.desktop) onDesktop(sdk.desktop);
    api = sdk;
    sync();
    let told = false;
    const tell = () => { if (!told) { told = true; onReady(); } };
    Promise.allSettled([...followers.values()].map((f) => f.first)).then(tell);
    setTimeout(tell, 4000);
  }

  /* ---------- reading the state ---------- */

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
    for (const { item } of state.components.values()) {
      const ref = text(item.ref);
      const held = by.get(ref);
      if (!held || newer(item.version, held.version)) by.set(ref, item);
    }
    return by;
  }
  const values = (map) => [...map.values()].map((h) => h.item);

  window.SB = {
    state, FEEDS, PAUSE, RESUME,
    start,
    subscribe(fn) { listeners.add(fn); },
    partOn,
    // Whether the page has the stream open (or opening).
    reading(key) { return followers.has(key); },
    // Whether the parts that are on, with `part` turned on as well, need
    // more streams than the page opens at once.
    tooMany(part) { return wanted((p) => p === part || partOn(p)).length > MOST; },
    attention: () => values(state.attention),
    threads: () => values(state.threads),
    schedules: () => values(state.schedules),
    vault: () => values(state.vault),
    activity: () => values(state.activity),
    components,
    componentRef, componentName, text, isItem,
  };
})();

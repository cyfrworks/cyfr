/* The switchboard's state: what the shell told the desktop at its open and
   since (installed apps, posture, covered, live or frozen, the desktop's
   preferences, appearance and person), and what each declared stream has
   said, current state first and then changes. Nothing here draws; board.js
   and plain.js read `SB.state` and are told when it changed. */
(function () {
  'use strict';

  // The streams the page reads, each named in the manifest's `data`.
  const STREAMS = [
    'attention.changes',
    'threads.changes',
    'components.changes',
    'runs.changes',
    'schedules.changes',
    'vault.changes',
    'activity.changes',
  ];
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
    // When each stream read now and then was last read.
    readAt: {},
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
      const unanswered = error && error.code === 'unavailable';
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

  // Streams the page keeps open, and streams it reads now and then. A
  // browser keeps six connections to one host over HTTP/1.1 and each open
  // stream holds one, and the server holds a frame to eight open streams,
  // counting a closed one until its next keep-alive write finds it gone
  // (up to about half a minute). So the page keeps five open, the ones the
  // lamps, the lines and the levers move with, and reads the other three
  // one at a time, each opened, its current state taken and closed: all
  // three at the start, then one a minute.
  const KEPT = ['attention.changes', 'threads.changes', 'components.changes', 'runs.changes', 'schedules.changes'];
  const TURNS = [['vault.changes', null], ['activity.changes', null], ['feed.results', 'weather']];
  const QUIET_MS = 800;      // a read's current state has come once it is this quiet,
  const READ_MS = 4000;      // or once the read has run this long
  const FIRST_GAP_MS = 2000; // the pause between the first reads
  const GAP_MS = 60000;      // and between every later one
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let soon = null;

  async function turns(sdk) {
    const opens = new Map();
    const refusedOnce = new Set();
    let round = 0;
    for (;;) {
      for (const [name, subject] of TURNS) {
        const key = subject ? `feed:${subject}` : name;
        if (refusedOnce.has(key)) continue;
        const n = (opens.get(key) || 0) + 1;
        opens.set(key, n);
        let last = Date.now();
        try {
          const stream = await sdk.stream(name, subject, ({ data }) => {
            if (!isItem(data)) return;
            last = Date.now();
            if (subject) foldFeed(subject, data); else fold(name, data, n);
          });
          const began = Date.now();
          last = began;
          while (Date.now() - began < READ_MS && Date.now() - last < QUIET_MS) await sleep(200);
          stream.close();
          if (!subject) opened(name, n);
          delete state.refusals[key];
          state.readAt[key] = new Date();
          changed(subject ? 'feeds' : SWEPT[name]);
        } catch (error) {
          // A refusal stands until something changes; no answer, or too
          // many open at once, is tried again on the next turn.
          const again = error && (error.code === 'unavailable' || error.code === 'rate_limited');
          if (!again) { refusedOnce.add(key); refused(key, error); }
        }
        // A read the person asked for (a feed's key pressed) comes sooner.
        const until = Date.now() + (round === 0 ? FIRST_GAP_MS : GAP_MS);
        while (Date.now() < until && !soon) await sleep(500);
        if (soon) { const k = soon; soon = null; const i = TURNS.findIndex(([n, sub]) => (sub ? `feed:${sub}` : n) === k); if (i >= 0) TURNS.push(...TURNS.splice(0, i)); break; }
      }
      round += 1;
    }
  }

  // Hears the shell, opens the kept streams, starts the turns, and calls
  // `ready()` once each kept stream's first open has its answer (opened,
  // refused, or unanswered and to be tried again), or after a few seconds,
  // whichever is first: the board is drawn by then either way.
  function start(sdk, onReady) {
    sdk.on('installed', onInstalled);
    sdk.on('covered', onCovered);
    sdk.on('posture', onPosture);
    sdk.on('state', onState);
    sdk.on('desktop', onDesktop);
    if (sdk.desktop) onDesktop(sdk.desktop);

    for (const name of KEPT) {
      followers.set(name, follow(sdk, name, null,
        (item, open) => fold(name, item, open),
        // A reopen's refresh arrives after the open: what an earlier open
        // delivered and this one did not is dropped once it has.
        (open) => setTimeout(() => opened(name, open), 2500),
        (error) => refused(name, error)));
    }
    let told = false;
    const tell = () => { if (!told) { told = true; onReady(); } };
    Promise.allSettled([...followers.values()].map((f) => f.first)).then(tell);
    setTimeout(tell, 4000);
    turns(sdk);
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
    state, STREAMS, FEEDS, PAUSE, RESUME,
    start,
    subscribe(fn) { listeners.add(fn); },
    // Reads a stream that is read now and then at its next chance, a few
    // seconds from now: `feed:<name>` or a stream's name.
    readSoon(key) { soon = key; },
    attention: () => values(state.attention),
    threads: () => values(state.threads),
    schedules: () => values(state.schedules),
    vault: () => values(state.vault),
    activity: () => values(state.activity),
    components,
    componentRef, componentName, text, isItem,
  };
})();

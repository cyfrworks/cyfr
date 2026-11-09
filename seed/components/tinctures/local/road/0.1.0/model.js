// Everything the road does apart from drawing: the streams it keeps open, how their events fold
// into one state, the person's preferences and the shell's handshake. The scene and the plain list
// both read Road.state and listen through Road.subscribe; neither writes it. Every call that asks
// CYFR to act (a press, a write, an open, an ask) is made from a tap, by the caller.
(function () {
  const sdk = window.cyfr || null;

  // Each stream stays open while the part that reads it is on. Every open holds a connection to
  // CYFR for as long as it runs, and a browser keeps six to one host over HTTP/1.1 (the shell and
  // its apps need the rest), so there the village reads five at once; over HTTP/2 it reads the
  // eight a desktop may open.
  const protocol = (() => { try { return performance.getEntriesByType('navigation')[0].nextHopProtocol || ''; } catch (e) { return ''; } })();
  const BUDGET = /^(h2|h3)/.test(protocol) ? 8 : 5;
  // The controls the manifest declares, each picking a schedule's id.
  const PAUSE = 'pause-schedule', RESUME = 'resume-schedule';
  // Pauses before opening an ended stream again, growing while opens fail.
  const RETRY_MS = [2000, 5000, 15000, 60000];
  // A reopened stream hands its whole current state first; what an earlier open delivered and
  // this one has not by then was removed meanwhile.
  const SETTLE_MS = 2500;
  const MAX_SCHEDULE_RUNS = 60;

  // The parts of the village, each a widget of the preferences document. `bld` are the buildings
  // a part stands on the street; `hill` parts keep their hill; `order` parts move along the street;
  // `streams` are what the part reads (a feed as `feed:<name>`); `on` is whether it stands before
  // the person says, the defaults reading five streams together.
  const PARTS = {
    attention: { name: 'Visitors', what: 'what waits on you', bld: [], streams: ['attention.changes'], on: true },
    threads: { name: 'Post boxes', what: 'threads', bld: ['post'], order: 1, streams: ['threads.changes'], on: true },
    activity: { name: 'Crew house', what: 'crew at work', bld: ['crew'], order: 2, streams: ['activity.changes'], on: true },
    components: { name: 'Market', what: 'your apps', bld: ['market'], order: 3, streams: [], on: true },
    schedules: { name: 'Tower and road', what: 'schedules and their runs', bld: ['tower', 'press', 'barn'], order: 4, streams: ['schedules.changes', 'schedule_runs.changes'], on: true },
    vault: { name: 'Strongroom', what: 'vault', bld: ['vault'], order: 5, streams: ['vault.changes'], on: false },
    weather: { name: 'Windmill', what: 'the weather feed', hill: true, streams: ['feed:weather'], on: false },
    vpn: { name: 'Tram line', what: 'the vpn feed', hill: true, streams: ['feed:vpn'], on: false },
  };

  const state = {
    attention: new Map(), schedules: new Map(), scheduleRuns: new Map(), threads: new Map(),
    activity: new Map(), vault: new Map(), feeds: { weather: null, vpn: null },
    refusals: {}, installed: [], posture: null, covered: [], frozen: false,
    prefs: { document: {}, revision: 0 }, appearance: null, person: null, framed: !!sdk,
  };

  const listeners = new Set();
  const emit = (change) => listeners.forEach((f) => { try { f(change); } catch (e) { console.error(e); } });

  // ---- the person's clock -------------------------------------------------------------------
  // Times are minutes on the person's own wall clock, counted from 1970-01-01 00:00 there, so a
  // day is a whole 1440 and the scene never meets a zone. The zone is the handshake's.
  let zone = null, fmt = null;
  const offsets = new Map();
  function setZone(z) {
    if (z === zone) return;
    try { fmt = new Intl.DateTimeFormat('en-US', { timeZone: z, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' }); zone = z; }
    catch (e) { fmt = null; zone = null; }
    offsets.clear();
  }
  function offsetMs(ms) {
    if (!fmt) return -new Date(ms).getTimezoneOffset() * 60000;
    const hour = Math.floor(ms / 3600000);
    if (offsets.has(hour)) return offsets.get(hour);
    const p = {};
    for (const part of fmt.formatToParts(new Date(hour * 3600000))) p[part.type] = Number(part.value);
    const off = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - hour * 3600000;
    if (offsets.size > 400) offsets.clear();
    offsets.set(hour, off);
    return off;
  }
  const localOf = (ms) => (ms + offsetMs(ms)) / 60000;
  const nowLocal = () => localOf(Date.now());
  // A wall-clock minute back to an instant: good to the hour a zone changes in.
  const utcOf = (m) => m * 60000 - offsetMs(m * 60000 - offsetMs(m * 60000));
  function timeOf(iso) {
    const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
    return Number.isNaN(t) ? null : localOf(t);
  }

  // ---- folding events -------------------------------------------------------------------------
  const isItem = (d) => typeof d === 'object' && d !== null && !Array.isArray(d);
  // "catalyst:local.openai:1.4.1" as a person reads it: "openai".
  const refName = (ref) => { const named = ref.split(':')[1] || ref; return named.includes('.') ? named.slice(named.indexOf('.') + 1) : named; };
  const str = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');

  function keep(map, key, value, open) { map.set(key, { value, open }); }

  function fold(stream, d, open) {
    switch (stream) {
      case 'attention.changes': {
        const id = str(d.id); if (!id) return;
        if (d.kind === 'removed') { if (state.attention.delete(id)) emit({ stream: 'attention', removed: id }); return; }
        const dest = isItem(d.destination) ? d.destination : {};
        const label = d.kind === 'failed_run' ? refName(str(d.label)) : str(d.label);
        keep(state.attention, id, { id, kind: str(d.kind), label: label || 'Something', since: timeOf(d.since), page: dest.kind === 'page' ? str(dest.page) : null }, open);
        break;
      }
      case 'schedules.changes': {
        const id = str(d.schedule_id); if (!id) return;
        if (d.kind === 'removed') { state.schedules.delete(id); break; }
        keep(state.schedules, id, {
          id, name: str(d.name) || str(d.reference) || 'A schedule', reference: str(d.reference), cron: str(d.cron_expression),
          status: str(d.status), next: timeOf(d.next_run_at), nextUtc: typeof d.next_run_at === 'string' ? Date.parse(d.next_run_at) : NaN,
          last: timeOf(d.last_run_at), runs: Number(d.run_count) || 0, errors: Number(d.error_count) || 0,
        }, open);
        break;
      }
      case 'schedule_runs.changes': {
        // once per occurrence and kind; a failure outranks the firing it followed
        const key = str(d.occurrence_id) || str(d.schedule_id) + '@' + str(d.scheduled_for) + '@' + str(d.execution_id);
        const before = state.scheduleRuns.get(key);
        if (before && before.value.kind === 'failed' && d.kind !== 'failed') return;
        const reason = isItem(d.reason) ? d.reason : null;
        keep(state.scheduleRuns, key, { key, kind: str(d.kind), sid: str(d.schedule_id), at: timeOf(d.scheduled_for), cause: reason ? str(reason.cause) : '' }, open);
        if (state.scheduleRuns.size > MAX_SCHEDULE_RUNS) {
          const oldest = [...state.scheduleRuns.values()].sort((a, b) => (a.value.at ?? -Infinity) - (b.value.at ?? -Infinity))[0];
          state.scheduleRuns.delete(oldest.value.key);
        }
        break;
      }
      case 'threads.changes': {
        const id = str(d.id); if (!id) return;
        if (d.kind === 'removed') { state.threads.delete(id); break; }
        keep(state.threads, id, { id, own: d.kind === 'own', title: str(d.title) || 'Untitled thread', people: Array.isArray(d.people) ? d.people.length : 0, last: timeOf(d.last_activity), waits: d.waits_on_you === true }, open);
        break;
      }
      case 'activity.changes': {
        const id = str(d.id); if (!id) return;
        if (d.kind === 'ended') { state.activity.delete(id); break; }
        keep(state.activity, id, { id, member: str(d.member) || 'crew', askedBy: str(d.asked_by), since: timeOf(d.since), status: str(d.status) }, open);
        break;
      }
      case 'vault.changes': {
        const name = str(d.name); if (!name) return;
        if (d.kind === 'removed') { state.vault.delete(name); break; }
        keep(state.vault, name, { name, type: str(d.type), fine: d.status !== 'needs_reauthorisation' }, open);
        break;
      }
      default: return;
    }
    emit({ stream: stream.split('.')[0] });
  }

  function foldFeed(name, d) {
    const held = state.feeds[name];
    const revision = Number(d.revision) || 0;
    if (held && held.revision >= revision) return;
    state.feeds[name] = {
      binding: str(d.binding), revision, at: timeOf(d.at), label: str(d.label), result: d.result,
      actions: Array.isArray(d.actions) ? d.actions.filter((a) => isItem(a) && str(a.name)).map((a) => ({ name: str(a.name), label: str(a.label) || str(a.name) })) : [],
    };
    emit({ stream: 'feeds', feed: name });
  }

  // After an open settles, drop what no open since `open` delivered.
  function prune(stream, open) {
    const map = { 'attention.changes': state.attention, 'schedules.changes': state.schedules, 'threads.changes': state.threads, 'activity.changes': state.activity, 'vault.changes': state.vault }[stream];
    if (!map) return;
    let changed = false;
    for (const [key, held] of map) if (held.open < open) {
      map.delete(key); changed = true;
      if (stream === 'attention.changes') emit({ stream: 'attention', removed: key });
    }
    if (changed) emit({ stream: stream.split('.')[0] });
  }

  // What each stream fills, emptied when its part turns off.
  function empty(key) {
    if (key.startsWith('feed:')) state.feeds[key.slice(5)] = null;
    else ({ 'attention.changes': state.attention, 'schedules.changes': state.schedules, 'schedule_runs.changes': state.scheduleRuns, 'threads.changes': state.threads, 'activity.changes': state.activity, 'vault.changes': state.vault })[key].clear();
    delete state.refusals[key.startsWith('feed:') ? key.slice(5) : key];
  }

  // ---- keeping a stream open ----------------------------------------------------------------
  // Every stream ends in time (its grant has a deadline, a connection breaks, a hidden desktop's
  // credential is suspended), so an ended stream is opened again after a pause and starts again
  // with its current state. Before it first opens, a refusal is final; an open the endpoint gave
  // no answer on (`unavailable`) is tried again. `kick` opens a waiting stream at once, for a
  // desktop shown again.
  const followers = new Map();
  function follow(name, subject, onItem, onOpen) {
    let stopped = false, opens = 0, ever = false, timer = null, waiting = false, current = null;
    async function open() {
      waiting = false;
      const n = ++opens;
      const handle = await sdk.stream(name, subject, ({ data }) => { if (!stopped && isItem(data)) onItem(data, n); });
      if (stopped) { handle.close(); return; }
      ever = true; current = handle;
      delete state.refusals[subject || name];
      onOpen(n);
      handle.closed.catch(() => {}).then(() => { current = null; retry(0); });
    }
    function failed(error, attempt) {
      if (stopped) return;
      if (!ever && !(error && error.code === 'unavailable')) {
        state.refusals[subject || name] = (error && error.message) || 'This could not be opened.';
        emit({ stream: 'refusal' });
      } else retry(attempt);
    }
    function retry(attempt) {
      if (stopped) return;
      waiting = true;
      clearTimeout(timer);
      timer = setTimeout(() => open().catch((e) => failed(e, Math.min(attempt + 1, RETRY_MS.length - 1))), RETRY_MS[attempt]);
    }
    return {
      first: open().catch((e) => failed(e, 0)),
      kick() { if (waiting && !stopped) { clearTimeout(timer); open().catch((e) => failed(e, 1)); } },
      stop() { stopped = true; clearTimeout(timer); if (current) current.close(); },
    };
  }
  function openKey(key) {
    if (key.startsWith('feed:')) { const feed = key.slice(5); return follow('feed.results', feed, (d) => foldFeed(feed, d), () => {}); }
    return follow(key, null, (d, n) => fold(key, d, n), (n) => setTimeout(() => prune(key, n), SETTLE_MS));
  }
  // The streams the parts that are on read, at most BUDGET of them, in the parts' order.
  function wanted() {
    const keys = [];
    for (const p of Object.keys(PARTS)) if (partOn(p)) for (const k of PARTS[p].streams) if (keys.length < BUDGET && !keys.includes(k)) keys.push(k);
    return keys;
  }
  // Opens what the parts on read and closes what no part on reads. Answers the new opens' firsts.
  function sync() {
    if (!sdk) return [];
    const keys = wanted(), firsts = [];
    for (const [key, f] of followers) if (!keys.includes(key)) { f.stop(); followers.delete(key); empty(key); emit({ stream: 'parts' }); }
    for (const key of keys) if (!followers.has(key)) { const f = openKey(key); followers.set(key, f); firsts.push(f.first); }
    return firsts;
  }
  // Whether turning `part` on keeps the streams read within the budget.
  function room(part) {
    const keys = new Set(wanted());
    for (const k of PARTS[part].streams) keys.add(k);
    return keys.size <= BUDGET;
  }

  // ---- preferences ----------------------------------------------------------------------------
  const widgetOf = (id) => { const w = isItem(state.prefs.document.widgets) ? state.prefs.document.widgets[id] : null; return isItem(w) ? w : {}; };
  // A part stands as its entry says, or as it stands by default while the person has said nothing.
  const partOn = (id) => (typeof widgetOf(id).on === 'boolean' ? widgetOf(id).on : PARTS[id].on);
  const units = () => (widgetOf('weather').units === 'f' ? 'f' : 'c');
  // The street's order: each part's stored place, else its own, ties by the default order.
  function order() {
    const ids = Object.keys(PARTS).filter((p) => PARTS[p].order);
    const at = (p) => (Number.isInteger(widgetOf(p).order) ? widgetOf(p).order : PARTS[p].order);
    return ids.sort((a, b) => at(a) - at(b) || PARTS[a].order - PARTS[b].order);
  }
  // A part's whole entry as it stands, changed by `change`: a write replaces the entry.
  function entry(id, change) {
    const e = { on: partOn(id) }, w = widgetOf(id);
    if (isItem(w.rect)) e.rect = w.rect;
    if (PARTS[id].order) e.order = Number.isInteger(w.order) ? w.order : PARTS[id].order;
    if (id === 'weather') e.units = units();
    return Object.assign(e, change);
  }
  function adopt(answer) {
    if (answer && isItem(answer.document)) {
      state.prefs = { document: answer.document, revision: Number(answer.revision) || state.prefs.revision };
      sync();
      emit({ stream: 'prefs' });
    }
  }
  // One tap, one write. Answers what the person reads when it did not save.
  async function write(widgets) {
    if (!sdk) return 'Your preferences are kept only inside CYFR.';
    let answer;
    try { answer = await sdk.prefs({ widgets }); } catch (e) { return 'Not saved: ' + ((e && e.message) || 'refused') + '.'; }
    adopt(answer);
    if (answer.outcome === 'saved') return null;
    if (answer.outcome === 'stale') return 'Another screen changed this first. Tap again.';
    if (answer.outcome === 'cancelled') return 'Not saved: tap once and wait a moment.';
    return 'Not saved: ' + (answer.reason || 'refused') + '.';
  }

  // ---- the handshake -------------------------------------------------------------------------
  function desktop(value) {
    if (!isItem(value)) return;
    if (isItem(value.prefs) && isItem(value.prefs.document)) state.prefs = { document: value.prefs.document, revision: Number(value.prefs.revision) || 0 };
    if (isItem(value.appearance)) { state.appearance = value.appearance; setZone(str(value.appearance.time_zone) || 'UTC'); }
    state.person = isItem(value.person) && str(value.person.name) ? str(value.person.name) : null;
    if (started) sync();
    emit({ stream: 'prefs' });
  }

  let started = false;
  // Starts reading. Answers a promise that settles once every first open has its answer, or after
  // three seconds: an open the browser holds back for a connection may wait far longer.
  function start() {
    if (!sdk) { emit({ stream: 'none' }); return Promise.resolve(); }
    desktop(sdk.desktop);
    sdk.on('desktop', desktop);
    sdk.on('installed', (list) => {
      state.installed = (Array.isArray(list) ? list : []).filter((a) => isItem(a) && str(a.ref) && str(a.name)).map((a) => ({ ref: a.ref, name: a.name, open: a.open === true }));
      emit({ stream: 'installed' });
    });
    sdk.on('posture', (p) => { if (p === 'hand' || p === 'desk') { state.posture = p; emit({ stream: 'posture' }); } });
    sdk.on('covered', (rects) => {
      state.covered = (Array.isArray(rects) ? rects : []).filter((r) => isItem(r) && ['x', 'y', 'width', 'height'].every((k) => Number.isFinite(r[k])));
      emit({ stream: 'covered' });
    });
    sdk.on('state', (s) => {
      state.frozen = s === 'frozen';
      if (!state.frozen) followers.forEach((f) => f.kick());
      emit({ stream: 'state' });
    });
    started = true;
    return Promise.race([Promise.allSettled(sync()), new Promise((r) => setTimeout(r, 3000))]);
  }

  window.Road = {
    state, PARTS, PAUSE, RESUME, subscribe: (f) => listeners.add(f), start,
    nowLocal, utcOf, localOf, partOn, units, order, entry, write, room, BUDGET,
    values: (map) => [...map.values()].map((held) => held.value),
    // What a press of a control answers, as a sentence when it did not run.
    async press(control, value) {
      if (!sdk) return 'Controls run only inside CYFR.';
      let answer;
      try { answer = await sdk.press(control, value); } catch (e) { return 'Not sent: ' + ((e && e.message) || 'refused') + '.'; }
      if (!answer || answer.outcome === 'accepted') return null;
      if (answer.outcome === 'cancelled') return 'Not sent: tap once and wait a moment.';
      return 'Refused: ' + (answer.reason || 'refused') + '.';
    },
    pressFeed(feed, action) { const f = state.feeds[feed]; if (sdk && f && f.binding) sdk.press(f.binding, action); },
    open: (ref) => sdk && sdk.open(ref),
    ask: (widget) => sdk && sdk.ask(widget),
    settings: (page) => sdk && sdk.settings(page),
    ready: () => sdk && sdk.ready(),
  };
})();

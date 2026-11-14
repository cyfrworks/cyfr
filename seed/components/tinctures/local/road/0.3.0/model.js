// Everything the road does apart from drawing: the streams it reads, how their events fold into
// one state, the person's preferences and the shell's handshake. The scene and the plain list
// both read Road.state and listen through Road.subscribe; neither writes it. Every call that asks
// CYFR to act (a press, a write, an open, an ask, a grant) is made from a tap, by the caller.
(function () {
  const sdk = window.cyfr || null;

  // What the manifest declares: every stream opens once, together, at the start, and stays open
  // whichever parts are on; they all ride the frame's one stream connection.
  const DATA = ['attention.changes', 'schedules.changes', 'schedule_runs.changes', 'runs.changes', 'threads.changes', 'activity.changes', 'components.changes', 'vault.changes', 'files.changes', 'system.changes'];
  const FEEDS = ['weather', 'vpn'];
  // How each stream names its items and which change takes one away (the delivery contract,
  // canvas.catalog): system.changes is one item; occurrences, runs and feed results never leave.
  const KEYS = {
    'attention.changes': ['id', 'removed'], 'schedules.changes': ['schedule_id', 'removed'], 'schedule_runs.changes': ['occurrence_id', null],
    'runs.changes': ['execution_id', null], 'threads.changes': ['id', 'removed'], 'activity.changes': ['id', 'ended'],
    'components.changes': ['ref', 'removed'], 'vault.changes': ['name', 'removed'], 'files.changes': ['id', 'removed'],
    'system.changes': [null, null], 'feed:weather': ['binding', null], 'feed:vpn': ['binding', null],
  };
  // A live change of these kinds says only that the picture moved: a fresh picture follows.
  const REREAD = { 'components.changes': ['installed', 'pushed', 'changed'] };
  // The controls the manifest declares: two pick a schedule's id, one a run's.
  const PAUSE = 'pause-schedule', RESUME = 'resume-schedule', RETRY = 'retry-run';
  // Pauses before opening again a stream that got no answer or ended, growing while it does.
  const RETRY_MS = [2000, 5000, 15000, 60000];
  const MAX_SCHEDULE_RUNS = 60;
  // runs.changes carries the 20 newest runs, the state the shell checks a retry against: the
  // village holds as many, so it never offers to run again a run the shell no longer reads.
  const MAX_RUNS = 20;
  // What a tap within a few seconds of the last one that reached CYFR is told: CYFR takes one
  // act per tap and answers the second `too_soon`, never holding it for later.
  const TOO_SOON = 'Too soon after your last tap: wait a few seconds, then tap again.';

  // The parts of the village, each a widget of the preferences document. `bld` are the buildings
  // a part stands on the street; `hill` parts keep their hill; `order` parts move along the street;
  // `streams` are what the part reads (a feed as `feed:<name>`), whose worst state it shows; `on`
  // is whether it stands before the person says.
  const PARTS = {
    // the porters read components.changes too, but the queue shows attention.changes' state alone
    attention: { name: 'Visitors', what: 'what waits on you', bld: [], streams: ['attention.changes'], on: true },
    threads: { name: 'Post boxes', what: 'threads', bld: ['post'], order: 1, streams: ['threads.changes'], on: true },
    activity: { name: 'Crew house', what: 'crew at work', bld: ['crew'], order: 2, streams: ['activity.changes', 'system.changes'], on: true },
    components: { name: 'Market', what: 'your apps', bld: ['market'], order: 3, streams: ['components.changes'], on: true },
    schedules: { name: 'Tower and road', what: 'schedules and their runs', bld: ['tower', 'press', 'barn'], order: 4, streams: ['schedules.changes', 'schedule_runs.changes', 'runs.changes'], on: true },
    vault: { name: 'Strongroom', what: 'vault', bld: ['vault'], order: 5, streams: ['vault.changes'], on: true },
    system: { name: 'Silo', what: 'how CYFR stands', bld: ['silo'], order: 6, streams: ['system.changes'], on: true },
    files: { name: 'Archive', what: 'your files', bld: ['archive'], order: 7, streams: ['files.changes'], on: false },
    weather: { name: 'Windmill', what: 'the weather feed', hill: true, streams: ['feed:weather'], on: true },
    vpn: { name: 'Tram line', what: 'the vpn feed', hill: true, streams: ['feed:vpn'], on: true },
  };

  const state = {
    attention: new Map(), schedules: new Map(), scheduleRuns: new Map(), runs: new Map(), threads: new Map(),
    activity: new Map(), components: new Map(), vault: new Map(), files: new Map(), system: new Map(),
    feeds: { weather: null, vpn: null }, installed: [], posture: null, covered: [], frozen: false,
    prefs: { document: {}, revision: 0 }, appearance: null, person: null, framed: !!sdk,
  };
  const feedItems = { weather: new Map(), vpn: new Map() };
  const MAPS = {
    'attention.changes': state.attention, 'schedules.changes': state.schedules, 'schedule_runs.changes': state.scheduleRuns, 'runs.changes': state.runs,
    'threads.changes': state.threads, 'activity.changes': state.activity, 'components.changes': state.components, 'vault.changes': state.vault,
    'files.changes': state.files, 'system.changes': state.system, 'feed:weather': feedItems.weather, 'feed:vpn': feedItems.vpn,
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
  const pad = (n) => String(n).padStart(2, '0');
  const clock = (m) => { const d = ((Math.floor(m) % 1440) + 1440) % 1440; return pad(Math.floor(d / 60)) + ':' + pad(d % 60); };

  // ---- reading an item ------------------------------------------------------------------------
  const isItem = (d) => typeof d === 'object' && d !== null && !Array.isArray(d);
  // "catalyst:local.openai:1.4.1" as a person reads it: "openai".
  const refName = (ref) => { const named = ref.split(':')[1] || ref; return named.includes('.') ? named.slice(named.indexOf('.') + 1) : named; };
  // "tincture:local.maps:1.0.0" without its version, as components.changes names it.
  const bare = (ref) => { const p = ref.split(':'); return p.length > 2 ? p[0] + ':' + p[1] : ref; };
  const str = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

  // An item's whole state as the scene reads it.
  function read(key, d) {
    switch (key) {
      case 'attention.changes': {
        const dest = isItem(d.destination) ? d.destination : {};
        const label = d.kind === 'failed_run' ? refName(str(d.label)) : str(d.label);
        return { id: str(d.id), kind: str(d.kind), label: label || 'Something', since: timeOf(d.since), page: dest.kind === 'page' ? str(dest.page) || null : null, ref: str(dest.ref) };
      }
      case 'schedules.changes':
        return {
          id: str(d.schedule_id), name: str(d.name) || str(d.reference) || 'A schedule', reference: str(d.reference), cron: str(d.cron_expression),
          status: str(d.status), next: timeOf(d.next_run_at), nextUtc: typeof d.next_run_at === 'string' ? Date.parse(d.next_run_at) : NaN,
          last: timeOf(d.last_run_at), runs: Number(d.run_count) || 0, errors: Number(d.error_count) || 0,
        };
      case 'schedule_runs.changes': {
        const reason = isItem(d.reason) ? d.reason : null;
        return { key: str(d.occurrence_id), kind: str(d.kind), sid: str(d.schedule_id), eid: str(d.execution_id), at: timeOf(d.scheduled_for), cause: reason ? str(reason.cause) : '' };
      }
      case 'runs.changes': {
        const error = isItem(d.error) ? d.error : null;
        return { id: str(d.execution_id), kind: str(d.kind), parent: str(d.parent_execution_id), name: refName(str(d.reference)) || 'A run', started: timeOf(d.started_at), ended: timeOf(d.ended_at), cause: error ? str(error.cause) : '' };
      }
      case 'threads.changes':
        return { id: str(d.id), own: d.kind === 'own', title: str(d.title) || 'Untitled thread', people: Array.isArray(d.people) ? d.people.length : 0, last: timeOf(d.last_activity), waits: d.waits_on_you === true, unread: num(d.unread) || 0 };
      case 'activity.changes':
        return { id: str(d.id), member: str(d.member) || 'crew', askedBy: str(d.asked_by), title: str(d.title), since: timeOf(d.since), status: str(d.status) };
      case 'components.changes':
        return { ref: str(d.ref), type: str(d.type), name: str(d.name), version: str(d.version), update: d.update_available === true, grant: typeof d.grant_current === 'boolean' ? d.grant_current : null };
      case 'vault.changes':
        return { name: str(d.name), type: str(d.type), fine: d.status !== 'needs_reauthorisation' };
      case 'files.changes':
        return { id: str(d.id), kind: str(d.kind), name: str(d.name) || 'A file', type: str(d.type), changed: timeOf(d.changed_at), from: str(d.from) };
      case 'system.changes':
        return { health: str(d.health), used: num(d.storage_used), cap: num(d.storage_cap), model: d.model_connected === true, ready: num(d.crew_ready), total: num(d.crew_total), version: str(d.version), update: d.update_available === true };
      default:
        return {
          binding: str(d.binding), revision: Number(d.revision) || 0, at: timeOf(d.at), label: str(d.label), result: d.result,
          actions: Array.isArray(d.actions) ? d.actions.filter((a) => isItem(a) && str(a.name)).map((a) => ({ name: str(a.name), label: str(a.label) || str(a.name) })) : [],
        };
    }
  }

  // ---- holding each stream's picture ------------------------------------------------------------
  // Per stream: the items it holds by key, each with the highest revision heard; the revisions of
  // items taken away, so an older change cannot bring one back; and, from an open or a `resync`
  // until the `snapshot`, the picture gathered apart, which then replaces what the stream held.
  const streams = {};
  const fresh = () => ({ items: new Map(), revs: new Map(), gone: new Map() });
  function holder(key) {
    return { key, items: MAPS[key], revs: new Map(), gone: new Map(), picture: null, state: 'opening', at: null, retryAt: null, opens: 0, tries: 0, timer: null };
  }
  const nameOf = (key) => (key.startsWith('feed:') ? 'feeds' : key === 'schedule_runs.changes' ? 'scheduleRuns' : key.split('.')[0]);
  function changed(key, removed) {
    if (key.startsWith('feed:')) {
      const feed = key.slice(5);
      let newest = null;
      for (const { value } of feedItems[feed].values()) if (!newest || value.revision >= newest.revision) newest = value;
      state.feeds[feed] = newest;
      emit({ stream: 'feeds', feed });
    } else emit(removed ? { stream: nameOf(key), removed } : { stream: nameOf(key) });
  }
  // Keeps the newest of a stream that never takes an item away.
  function cap(key, into) {
    const most = key === 'runs.changes' ? MAX_RUNS : key === 'schedule_runs.changes' ? MAX_SCHEDULE_RUNS : Infinity;
    if (into.items.size <= most) return;
    const when = (v) => (key === 'runs.changes' ? v.started : v.at) ?? -Infinity;
    const [id] = [...into.items].sort((a, b) => when(a[1].value) - when(b[1].value))[0];
    into.gone.set(id, into.revs.get(id)); into.items.delete(id); into.revs.delete(id);
  }
  function change(s, d, revision) {
    const [field, removal] = KEYS[s.key];
    const id = field ? str(d[field]) : 'one';
    // a schedule that failed before it claimed an occurrence: a notice to show, never to hold
    if (!id) { if (s.key === 'schedule_runs.changes') emit({ stream: 'notice', notice: read(s.key, d) }); return; }
    if (d.refresh !== true && (REREAD[s.key] || []).includes(d.kind)) return;
    const into = s.picture || s;
    const rev = Number.isInteger(revision) ? revision : null;
    const before = into.revs.has(id) ? into.revs.get(id) : into.gone.get(id);
    if (rev !== null && before != null && rev <= before) return;
    if (removal && d.kind === removal) {
      into.items.delete(id); into.revs.delete(id); into.gone.set(id, rev);
    } else {
      into.items.set(id, { value: read(s.key, d) }); into.revs.set(id, rev); into.gone.delete(id);
      cap(s.key, into);
    }
    // only a live removal is told as one: an item a picture drops is simply gone
    if (!s.picture) changed(s.key, removal && d.kind === removal ? id : null);
  }
  function replace(s) {
    const p = s.picture;
    s.picture = null;
    s.items.clear();
    for (const [id, held] of p.items) s.items.set(id, held);
    s.revs = p.revs; s.gone = p.gone;
    changed(s.key);
  }
  function setState(s, st, o = {}) {
    s.state = st; s.at = o.at ?? null; s.retryAt = o.retryAt ?? null;
    emit({ stream: 'states' });
  }
  function heard(s, ev) {
    const event = ev && ev.event;
    if (event === 'resync') { s.picture = fresh(); return; }
    if (event === 'snapshot') { if (s.picture) replace(s); s.tries = 0; return setState(s, 'live'); }
    if (event === 'stale') return setState(s, 'stale', { at: timeOf(ev.at) });
    if (event === 'unavailable') return setState(s, 'unavailable', { retryAt: timeOf(isItem(ev.data) ? ev.data.retry_at : null) });
    if (event === 'denied') { s.picture = null; s.items.clear(); s.revs.clear(); s.gone.clear(); changed(s.key); return setState(s, 'denied'); }
    if (event === 'refusal' || !isItem(ev.data)) return;
    change(s, ev.data, ev.revision);
  }

  // ---- opening a stream -----------------------------------------------------------------------
  // The SDK opens an opened stream again by itself after a lost connection. The page opens one
  // again only when its first open got no answer (`unavailable`), or when it ended with no
  // refusal (as at its grant's day-long bound), after a pause that grows while that repeats.
  // Any other refusal is final: the part says so.
  function open(s) {
    clearTimeout(s.timer); s.timer = null;
    const n = ++s.opens;
    s.picture = fresh();
    const feed = s.key.startsWith('feed:') ? s.key.slice(5) : null;
    let opening;
    try { opening = sdk.stream(feed ? 'feed.results' : s.key, feed, (ev) => { if (s.opens === n) heard(s, ev); }); }
    catch (e) { opening = Promise.reject(e); }
    return Promise.resolve(opening).then((handle) => {
      if (s.opens !== n) { handle.close(); return; }
      setState(s, 'live');
      const ended = () => { if (s.opens === n && handle.state === 'ended') later(s); };
      handle.closed.then(ended, ended);
    }, (error) => {
      if (s.opens !== n) return;
      s.picture = null;
      const code = error && error.code;
      if (code === 'unavailable') later(s);
      else setState(s, code === 'forbidden' ? 'forbidden' : 'failed');
    });
  }
  function later(s) {
    const wait = RETRY_MS[Math.min(s.tries++, RETRY_MS.length - 1)];
    setState(s, 'unavailable', { retryAt: localOf(Date.now() + wait) });
    s.timer = setTimeout(() => open(s), wait);
  }

  // What a part says of the worst state among its streams, in the village's words, or null
  // while every one is live.
  const RANK = { opening: 0, live: 0, stale: 1, unavailable: 2, failed: 3, forbidden: 4, denied: 4 };
  function note(part) {
    let worst = null;
    for (const key of PARTS[part].streams) { const s = streams[key]; if (s && RANK[s.state] > (worst ? RANK[worst.state] : 0)) worst = s; }
    if (!worst) return null;
    const text = {
      stale: 'as of ' + (worst.at != null ? clock(worst.at) : 'earlier'),
      unavailable: worst.retryAt != null ? 'trying again at ' + clock(worst.retryAt) : 'trying again soon',
      failed: 'could not be read', forbidden: 'not granted', denied: 'no longer granted',
    }[worst.state];
    return { state: worst.state, text };
  }

  // What waits on the person: the attention items, and an installed app whose grant is not
  // current, a porter at the house. An offer names its sender when the files stream holds it.
  function waiting() {
    const out = [];
    for (const { value: a } of state.attention.values()) {
      const offer = a.kind === 'file_offer' && state.files.get(a.ref);
      out.push(offer && offer.value.from ? { ...a, from: offer.value.from } : a);
    }
    for (const app of state.installed) {
      const c = state.components.get(bare(app.ref));
      if (c && c.value.grant === false) out.push({ id: 'grant:' + app.ref, kind: 'grant', label: app.name, ref: app.ref, since: null, page: null });
    }
    return out;
  }
  const component = (ref) => { const c = state.components.get(bare(ref)); return c ? c.value : null; };
  // A run CYFR may run again: held among the latest runs, failed, and a root run.
  const retryable = (id) => { const h = id && state.runs.get(id); return !!h && h.value.kind === 'failed' && !h.value.parent; };

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
    if (answer.outcome === 'cancelled') return answer.reason === 'too_soon' ? TOO_SOON : 'Not saved: tap once and wait a moment.';
    return 'Not saved: ' + (answer.reason || 'refused') + '.';
  }

  // ---- the handshake -------------------------------------------------------------------------
  function desktop(value) {
    if (!isItem(value)) return;
    if (isItem(value.prefs) && isItem(value.prefs.document)) state.prefs = { document: value.prefs.document, revision: Number(value.prefs.revision) || 0 };
    if (isItem(value.appearance)) { state.appearance = value.appearance; setZone(str(value.appearance.time_zone) || 'UTC'); }
    state.person = isItem(value.person) && str(value.person.name) ? str(value.person.name) : null;
    emit({ stream: 'prefs' });
  }

  // Starts reading. Answers a promise that settles once every first open has its answer, or after
  // three seconds: a hidden desktop's opens wait until it is shown.
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
    sdk.on('state', (s) => { state.frozen = s === 'frozen'; emit({ stream: 'state' }); });
    const firsts = [...DATA, ...FEEDS.map((f) => 'feed:' + f)].map((key) => open((streams[key] = holder(key))));
    return Promise.race([Promise.allSettled(firsts), new Promise((r) => setTimeout(r, 3000))]);
  }

  // What a press of `retry-run` answers, in the village's words.
  const REFUSED = {
    conflict: 'This run cannot be run again: only a run a schedule or a feed started, known to have failed, runs again.',
    invalid_argument: 'This run is no longer among the latest runs.',
    not_found: 'This run is gone.',
    forbidden: 'This run is not yours to run again.',
    unavailable: 'CYFR cannot run it now. Try again shortly.',
    rate_limited: 'CYFR cannot run it now. Try again shortly.',
    timeout: 'CYFR cannot run it now. Try again shortly.',
    uncertain: 'No answer came. Look at Runs before trying again.',
  };
  async function retry(id) {
    if (!sdk) return 'Runs are run again only inside CYFR.';
    let answer;
    try { answer = await sdk.press(RETRY, id); } catch (e) { return 'It could not be run again.'; }
    if (answer && answer.outcome === 'accepted') return 'Sent: it runs again.';
    if (answer && answer.outcome === 'cancelled') return answer.reason === 'too_soon' ? TOO_SOON : 'Nothing ran.';
    return (answer && REFUSED[answer.reason]) || 'It could not be run again.';
  }

  window.Road = {
    state, PARTS, PAUSE, RESUME, subscribe: (f) => listeners.add(f), start,
    nowLocal, utcOf, localOf, partOn, units, order, entry, write, note, waiting, component, retryable, retry,
    values: (map) => [...map.values()].map((held) => held.value),
    // What a press of a control answers, as a sentence when it did not run.
    async press(control, value) {
      if (!sdk) return 'Controls run only inside CYFR.';
      let answer;
      try { answer = await sdk.press(control, value); } catch (e) { return 'Not sent: ' + ((e && e.message) || 'refused') + '.'; }
      if (!answer || answer.outcome === 'accepted') return null;
      if (answer.outcome === 'cancelled') return answer.reason === 'too_soon' ? TOO_SOON : 'Not sent: tap once and wait a moment.';
      return 'Refused: ' + (answer.reason || 'refused') + '.';
    },
    pressFeed(feed, action) { const f = state.feeds[feed]; if (sdk && f && f.binding) sdk.press(f.binding, action); },
    open: (ref) => sdk && sdk.open(ref),
    ask: (widget) => sdk && sdk.ask(widget),
    // a page, at `ref` when there is one: AQUA's panel at an own thread, the chat at a shared one
    settings: (page, ref) => sdk && (ref ? sdk.settings(page, ref) : sdk.settings(page)),
    grant: (ref) => sdk && sdk.grant(ref),
    ready: () => sdk && sdk.ready(),
  };
})();

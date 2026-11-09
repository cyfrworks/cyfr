/* The switchboard: every thing in the person's place is a line with a jack.
   A line that waits on the person lights its lamp (amber calling, red
   fault). Tapping a line lifts its cord; tapping one of the four position
   jacks (app, chat, AQUA, settings) patches it through, which is the only
   way the board acts on a line. The cord stays in while the call waits and
   is pulled when the attention stream says it cleared. Lamps report; caps
   act: the levers press the declared controls, a feed's keys press its
   actions, and the rack writes the person's preferences, each on a tap. */
(function () {
  'use strict';

  const { state, PAUSE, RESUME, text, isItem, componentRef, componentName } = window.SB;
  const html = document.documentElement;

  /* ---------- time, in the person's own zone and words ---------- */
  function intl(options) {
    const zone = state.appearance.time_zone;
    try { return new Intl.DateTimeFormat(state.appearance.locale, { ...options, timeZone: zone }); } catch (_) {
      try { return new Intl.DateTimeFormat(undefined, options); } catch (_e) { return new Intl.DateTimeFormat('en-GB', options); }
    }
  }
  const parse = (iso) => { const t = typeof iso === 'string' ? Date.parse(iso) : NaN; return Number.isNaN(t) ? null : new Date(t); };
  const two = (n) => String(n).padStart(2, '0');
  function clockParts(d) {
    const out = {};
    for (const p of intl({ hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' }).formatToParts(d)) out[p.type] = p.value;
    return { y: +out.year, m: +out.month, d: +out.day, h: +out.hour % 24, mi: +out.minute, s: +out.second };
  }
  const dayNumber = (d) => { const p = clockParts(d); return Math.round(Date.UTC(p.y, p.m - 1, p.d) / 864e5); };
  const hm = (d) => { const p = clockParts(d); return `${two(p.h)}:${two(p.mi)}`; };
  const weekday = (d) => intl({ weekday: 'short' }).format(d);
  function relWord(days) {
    try { return new Intl.RelativeTimeFormat(state.appearance.locale, { numeric: 'auto' }).format(days, 'day'); } catch (_) { return days > 0 ? 'tomorrow' : 'yesterday'; }
  }
  // When something was or will be, as briefly as the board can say it.
  function rel(iso, absent = '—', brief = false) {
    const d = parse(iso); if (!d) return absent;
    const diff = dayNumber(d) - dayNumber(new Date());
    if (diff === 0) return hm(d);
    if (diff === 1 && !brief) return `${relWord(diff)} ${hm(d)}`;
    if (Math.abs(diff) < 7) return `${weekday(d)} ${hm(d)}`;
    return intl({ day: 'numeric', month: 'short' }).format(d);
  }
  const secs = (ms) => (Number.isFinite(ms) ? (ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`) : '');

  /* ---------- words ---------- */
  const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const KIND = { approval: 'Approval', confirmation: 'Confirmation', failed_run: 'Failed run', failed_schedule: 'Fire failed', file_offer: 'File offer' };
  // A few words for a failure, by its cause: the board's own, since the
  // readable sentence each cause has in the stream's shape reaches the
  // catalog and not the page.
  const CAUSE = {
    failed: 'Failed', cancelled: 'Cancelled', timed_out: 'Timed out', refused: 'Refused', needs_setup: 'Needs setup',
    waits_for_you: 'Waits for you', rate_limited: 'Rate limited', unavailable: 'Unavailable', bad_input: 'Bad input',
    not_found: 'Not found', uncertain: 'Uncertain',
  };
  const cause = (error) => (isItem(error) && CAUSE[error.cause]) || 'Failed';
  const tilt = (t) => { let h = 0; for (const c of String(t)) h = (h * 31 + c.charCodeAt(0)) | 0; return ((h % 13) / 13) * 1.4 - 0.7; };
  const dymo = (t, cls = '') => `<span class="dymo ${cls}" style="--tilt:${tilt(t).toFixed(2)}deg">${esc(t)}</span>`;
  const words = (key) => String(key).replace(/_(c|f|kmh|mbps|pct)$/, '').replace(/_/g, ' ');

  /* ---------- the parts, each a widget of the preferences document ---------- */
  const PARTS = {
    calls: { zone: 'field', title: 'Calls', page: null },
    threads: { zone: 'field', title: 'Threads', page: 'chat' },
    apps: { zone: 'field', title: 'Apps', page: 'components' },
    components: { zone: 'field', title: 'Components', page: 'components' },
    weather: { zone: 'meters', title: 'Weather', page: 'components' },
    schedules: { zone: 'shelf', title: 'Schedules', page: 'schedules' },
    runs: { zone: 'shelf', title: 'Runs', page: 'executions' },
    vault: { zone: 'shelf', title: 'Vault', page: 'vault' },
    crew: { zone: 'shelf', title: 'Crew', page: 'activities' },
  };
  const ORDER = Object.fromEntries(['field', 'meters', 'shelf'].flatMap((z) => Object.keys(PARTS).filter((k) => PARTS[k].zone === z).map((k, i) => [k, i])));
  const DEST = [
    { id: 'app', name: 'App' },
    { id: 'chat', name: 'Chat' },
    { id: 'aqua', name: 'AQUA' },
    { id: 'settings', name: 'Settings' },
  ];

  const widgets = () => (isItem(state.prefs.document) && isItem(state.prefs.document.widgets) ? state.prefs.document.widgets : {});
  const entry = (id) => (isItem(widgets()[id]) ? widgets()[id] : {});
  const isOn = (id) => entry(id).on !== false;
  const orderOf = (id) => (Number.isInteger(entry(id).order) ? entry(id).order : ORDER[id]);
  const celsius = () => entry('weather').units !== 'f';

  let sdk = null;
  let root = null;
  const $ = (s, el = root) => el.querySelector(s);
  const $$ = (s, el = root) => [...el.querySelectorAll(s)];
  let posEl = {};

  /* ---------- the readout: what the board just did, else the summary ---------- */
  let note = null, noteTimer = 0;
  function tell(t, ms = 3600) { note = t; clearTimeout(noteTimer); noteTimer = setTimeout(() => { note = null; summary(); }, ms); summary(); }
  function summary() {
    const calling = state.attention.size;
    const busy = state.activity.size + state.runs.filter((r) => r.kind === 'started').length;
    const unread = state.refusals['attention.changes'] ? 'calls unreadable' : `${calling} calling`;
    $('.readout-text').textContent = note || `${unread} · ${busy} busy`;
  }
  function tick() {
    const d = new Date();
    const p = clockParts(d);
    $('.clock-day').textContent = `${weekday(d)} ${p.d} ${intl({ month: 'short' }).format(d)}`;
    $('.clock-hm').textContent = `${two(p.h)}:${two(p.mi)}`;
    $('.clock-s').textContent = `:${two(p.s)}`;
  }

  /* ---------- the skeleton ---------- */
  const askJack = (part) => `<button class="askjack" data-ask="${part}" aria-label="Lift the ${PARTS[part].title} cord: patch to AQUA or settings"><span class="jack sm"><span class="hole"></span></span></button>`;
  const modHead = (part, extra = '') => `<header class="mod-hd"><h2>${PARTS[part].title}</h2><span class="mod-sub"></span>${extra}${askJack(part)}</header>`;
  const strip = (part) => `<div class="strip" data-part="${part}"><h2 class="strip-tag">${PARTS[part].title}</h2><div class="cells" data-group="${part}"></div></div>`;
  const KNOB = '<button class="knob" data-knob aria-label="Units"><span class="knob-c">°C</span><span class="knob-dial"></span><span class="knob-f">°F</span></button>';

  function skeleton() {
    root.innerHTML = `
      <header class="hdr">
        <h1 class="badge"><span class="badge-cyfr">CYFR</span><span class="badge-place"></span></h1>
        <div class="vfd clock" role="timer" aria-label="Time"><span class="clock-day"></span><b class="clock-hm"></b><i class="clock-s"></i></div>
        <div class="vfd readout" aria-live="polite"><span class="readout-text"></span></div>
        <button class="key rack-key" aria-pressed="false">Rack</button>
      </header>
      <section class="upper">
        <div class="field" data-zone="field" aria-label="Lines">${['calls', 'threads', 'apps', 'components'].map(strip).join('')}</div>
        <nav class="position" aria-label="Patch to">
          ${DEST.map((d) => `<button class="pos" data-dest="${d.id}" disabled aria-label="Patch to ${d.name}"><span class="pos-name">${d.name}</span><span class="jack lg"><span class="hole"></span></span><span class="pos-hint"></span></button>`).join('')}
        </nav>
        <div class="meters" data-zone="meters">
          <section class="mod weather" data-part="weather">${modHead('weather', KNOB)}<div class="wx"><div class="vfd wx-now"></div><div class="wx-side"><p class="wx-cap"></p><ol class="wx-hours"></ol><div class="trunk-row"></div><p class="wx-at"></p><div class="wx-keys"></div></div></div></section>
        </div>
      </section>
      <section class="shelf" data-zone="shelf">
        <section class="mod schedules" data-part="schedules">${modHead('schedules')}<div class="seq"></div></section>
        <section class="mod runs" data-part="runs">${modHead('runs')}<div class="printer"><div class="slot"></div><ol class="paper"></ol></div></section>
        <section class="mod vault" data-part="vault">${modHead('vault')}<div class="annun vault-annun"></div></section>
        <section class="mod crew" data-part="crew">${modHead('crew')}<div class="jobs"></div>
          <p class="code" aria-label="Lamp code"><span data-lamp="amber"><span class="lamp"></span>calling</span><span data-lamp="red"><span class="lamp"></span>fault</span><span data-lamp="green"><span class="lamp"></span>in service</span><span data-lamp="white"><span class="lamp"></span>busy</span></p></section>
      </section>
      <div class="spares" hidden><span class="spares-tag">Spares</span><div class="spares-list"></div><button class="key" data-rackdone>Done</button></div>`;
    posEl = Object.fromEntries($$('.pos').map((b) => [b.dataset.dest, b]));
  }

  /* ---------- lines ---------- */
  // Each waiting item finds the line it is about: an approval its thread, a
  // failed run its component, a failed schedule the component it runs.
  // What finds no line, or comes second to one, calls on a line of its own.
  function lineModel() {
    const comps = window.SB.components();
    const threads = window.SB.threads();
    const threadIds = new Set(threads.map((t) => t.id));
    const onThread = new Map(), onComp = new Map(), loose = [];
    const calls = window.SB.attention().sort((a, b) => text(a.since).localeCompare(text(b.since)));
    for (const a of calls) {
      const dest = isItem(a.destination) ? a.destination : {};
      let key = null, into = null;
      if (a.kind === 'approval' && threadIds.has(dest.ref)) { key = dest.ref; into = onThread; }
      if (a.kind === 'failed_run' && comps.has(componentRef(a.id))) { key = componentRef(a.id); into = onComp; }
      if (a.kind === 'failed_schedule') {
        const held = state.schedules.get(a.id);
        const ref = held ? componentRef(held.item.reference) : '';
        if (comps.has(ref)) { key = ref; into = onComp; }
      }
      if (into && !into.has(key)) into.set(key, a); else loose.push(a);
    }
    const fault = (a) => a.kind === 'failed_run' || a.kind === 'failed_schedule';
    const settingsOf = (a, fallback) => (isItem(a.destination) && a.destination.kind === 'page' && a.destination.page) || fallback;
    const out = { calls: [], threads: [], apps: [], components: [] };

    for (const a of loose) {
      const dest = isItem(a.destination) ? a.destination : {};
      const page = dest.kind === 'page' ? dest.page : null;
      const target = page === 'chat' ? 'chat' : page ? 'settings' : null;
      out.calls.push({
        id: `call:${a.id}`, widget: 'calls', kind: a.kind, name: text(a.label) || KIND[a.kind] || 'Call', call: a,
        lamp: fault(a) ? 'red' : 'amber', meta: [KIND[a.kind] || 'Call', rel(a.since)],
        targets: target ? [target, 'aqua'] : ['aqua'], primary: target || 'aqua', page,
      });
    }
    for (const t of threads.sort((a, b) => text(b.last_activity).localeCompare(text(a.last_activity)))) {
      const call = onThread.get(t.id) || null;
      const people = Array.isArray(t.people) ? t.people.length : 0;
      const who = t.kind === 'own' ? 'Own' : people > 0 ? `${people} people` : 'Shared';
      const waits = call || t.waits_on_you === true;
      out.threads.push({
        id: `thread:${t.id}`, widget: 'threads', kind: 'thread', name: text(t.title) || 'Untitled', call,
        lamp: waits ? 'amber' : 'off', meta: call ? [KIND[call.kind], rel(call.since)] : waits ? ['Waits on you', rel(t.last_activity)] : [who, rel(t.last_activity)],
        targets: ['chat', 'aqua'], primary: 'chat', page: 'chat',
      });
    }
    for (const app of state.installed) {
      const c = comps.get(componentRef(app.ref));
      const v = c && c.version ? `v${text(c.version)}` : '';
      out.apps.push({
        id: `app:${app.ref}`, widget: 'apps', kind: 'app', name: app.name, ref: app.ref, call: null,
        lamp: app.open ? 'green' : 'off', meta: app.open ? ['Open', v] : c && c.update_available === true ? ['Update', v] : ['', v],
        targets: ['app', 'settings', 'aqua'], primary: 'app', page: 'components',
      });
    }
    // The components a line stands for, by name, the ones calling first: a
    // jack keeps its place while runs come and go, and moves only when its
    // call starts or clears.
    const lastRun = new Map();
    state.runs.forEach((r) => { const ref = componentRef(r.reference); if (!lastRun.has(ref)) lastRun.set(ref, { run: r }); });
    const lines = [...comps.values()].filter((c) => c.type !== 'tincture' && c.type !== 'agent')
      .sort((a, b) => (onComp.has(b.ref) ? 1 : 0) - (onComp.has(a.ref) ? 1 : 0) || text(a.name).localeCompare(text(b.name)));
    for (const c of lines) {
      const call = onComp.get(c.ref) || null;
      const last = lastRun.get(c.ref);
      const run = last && last.run;
      const v = c.version ? `v${text(c.version)}` : '';
      const meta = call ? [KIND[call.kind], rel(call.since)]
        : run ? [run.kind === 'started' ? 'Running' : run.kind === 'completed' ? `OK ${secs(run.duration_ms)}` : run.kind === 'failed' ? cause(run.error) : 'Cancelled', v]
          : ['No run yet', v];
      out.components.push({
        id: `component:${c.ref}`, widget: 'components', kind: text(c.type), name: text(c.name) || componentName(c.ref), call,
        lamp: call ? (fault(call) ? 'red' : 'amber') : run && run.kind === 'started' ? 'white' : 'off', meta,
        targets: ['settings', 'aqua'], primary: 'settings', page: call ? settingsOf(call, 'components') : 'components',
      });
    }
    return out;
  }

  const lineIndex = new Map();
  function renderLines() {
    const model = lineModel();
    lineIndex.clear();
    for (const [group, items] of Object.entries(model)) {
      const box = $(`.cells[data-group="${group}"]`);
      box.closest('.strip').dataset.empty = items.length ? 'no' : 'yes';
      const keep = new Set(items.map((l) => l.id));
      for (const el of [...box.children]) if (!keep.has(el.dataset.line)) el.remove();
      items.forEach((l, i) => {
        let el = box.querySelector(`[data-line="${CSS.escape(l.id)}"]`);
        if (!el) {
          el = document.createElement('button');
          el.className = 'line'; el.dataset.line = l.id;
          el.innerHTML = `<span class="jack"><span class="hole"></span></span><span class="lamp"></span>${dymo(l.name)}<span class="meta"><span class="meta-a"></span><span class="meta-b"></span></span>`;
          el.addEventListener('click', () => onLine(l.id));
        }
        if (box.children[i] !== el) box.insertBefore(el, box.children[i] || null);
        const was = el.dataset.lamp;
        el.dataset.lamp = l.lamp;
        if (l.call && !l.call.refresh && was !== l.lamp && (l.lamp === 'amber' || l.lamp === 'red')) { el.classList.add('ringing'); setTimeout(() => el.classList.remove('ringing'), 6000); }
        $('.dymo', el).textContent = l.name;
        $('.meta-a', el).textContent = l.meta[0]; $('.meta-b', el).textContent = l.meta[1];
        el.setAttribute('aria-label', `${l.name}, ${l.call ? `${KIND[l.call.kind] || 'call'} waiting since ${rel(l.call.since)}` : l.meta.filter(Boolean).join(', ')}. Lift the cord`);
        lineIndex.set(l.id, l);
      });
      // Short screens give each line more room: four to a row there.
      const most = innerHeight <= 640 && innerWidth < 1200 ? 4 : 6;
      const n = Math.max(1, Math.min(most, items.length));
      box.style.setProperty('--n', n);
      // A strip's share of the field follows how many rows of lines it holds.
      box.closest('.strip').style.setProperty('--rows', Math.min(2, Math.max(1, Math.ceil(items.length / n))));
    }
    // A cord whose call cleared comes out, and its lamp cools.
    for (const [callId, rope] of patches) {
      if (state.attention.has(callId)) continue;
      rope.hold = false; rope.retract(); patches.delete(callId);
      const el = $$('.line.patched').find((x) => !(lineIndex.get(x.dataset.line) || {}).call);
      const name = el ? (lineIndex.get(el.dataset.line) || {}).name : '';
      if (el) { el.classList.remove('patched'); el.classList.add('cooling'); setTimeout(() => el.classList.remove('cooling'), 1600); }
      tell(`Cleared${name ? ` · ${name}` : ''} ${hm(new Date())}`);
    }
    if (hand && hand.line.id && !lineIndex.has(hand.line.id) && !hand.line.module) drop();
  }

  /* ---------- the cord in the hand, and patches ---------- */
  let hand = null;               // { el, rope, line }
  const patches = new Map();     // attention id -> rope
  function onLine(id) {
    const l = lineIndex.get(id);
    if (!l) return;
    const el = root.querySelector(`[data-line="${CSS.escape(id)}"]`);
    const open = l.call && patches.get(l.call.id);
    if (open) { open.retract(); patches.delete(l.call.id); el.classList.remove('patched'); tell(`Pulled · ${l.name}`); return; }
    lift(el, el.querySelector('.jack'), l);
  }
  function lift(el, jack, line) {
    if (hand && hand.el === el) { drop(); return; }
    if (hand) drop(true);
    const rope = window.Cords.pick(jack);
    hand = { el, rope, line };
    el.classList.add('lifted');
    root.dataset.hand = 'on';
    for (const d of DEST) {
      const b = posEl[d.id];
      const ok = line.targets.includes(d.id);
      b.disabled = !ok;
      b.dataset.target = !ok ? 'no' : d.id === line.primary ? 'primary' : 'ok';
      $('.pos-hint', b).textContent = d.id === line.primary ? (line.call ? 'resolves here' : 'usual') : '';
    }
    if (line.call && line.call.kind === 'confirmation') { tell(`${line.name} · CYFR asks you this itself`, 60000); return; }
    tell(`${line.name} · patch to ${line.targets.map((t) => DEST.find((d) => d.id === t).name).join(', ')}`, 60000);
  }
  function clearPositions() {
    for (const b of Object.values(posEl)) { b.disabled = true; delete b.dataset.target; }
  }
  function drop(quiet) {
    if (!hand) return;
    hand.rope.retract();
    hand.el.classList.remove('lifted');
    hand = null;
    delete root.dataset.hand;
    clearPositions();
    if (!quiet) { note = null; summary(); }
  }
  function patch(dest) {
    if (!hand || !hand.line.targets.includes(dest)) return;
    const { el, rope, line } = hand;
    hand = null; delete root.dataset.hand;
    el.classList.remove('lifted');
    clearPositions();
    rope.patch($('.jack', posEl[dest]), { slack: 1.02, extra: 14 });
    posEl[dest].classList.add('lit'); setTimeout(() => posEl[dest].classList.remove('lit'), 1600);
    // A call patched to where it resolves keeps its cord in until it clears;
    // any other patch is a plain open, and the cord comes home.
    const resolves = line.call && dest === line.primary;
    if (resolves) { patches.set(line.call.id, rope); el.classList.add('patched'); } else setTimeout(() => rope.retract(), 2200);
    act(line, dest);
  }
  function act(line, dest) {
    const name = line.name;
    if (dest === 'aqua') { sdk.ask(line.widget); tell(`${name} → AQUA · nothing sent`); return; }
    if (dest === 'chat') { sdk.settings('chat'); tell(`${name} → chat`); return; }
    if (dest === 'app') { sdk.open(line.ref); tell(`${name} → app`); return; }
    if (dest === 'settings' && line.page) { sdk.settings(line.page); tell(`${name} → settings`); }
  }

  /* ---------- the weather feed: a meter reading whatever the feed says ---------- */
  let wxWaiting = null;
  function temp(key, n) {
    if (!/_c$/.test(key) || celsius()) return n;
    return Math.round((n * 9) / 5 + 32);
  }
  function renderWeather() {
    const f = state.feeds.weather;
    const refusal = state.refusals['feed:weather'];
    const r = f && f.result;
    $('.weather h2').textContent = (f && text(f.label)) || PARTS.weather.title;
    $('.weather .mod-sub').textContent = f && parse(f.at) ? rel(f.at) : state.readAt['feed:weather'] ? `as of ${hm(state.readAt['feed:weather'])}` : '';
    const now = $('.wx-now'), hours = $('.wx-hours'), trunks = $('.trunk-row'), keys = $('.wx-keys');
    if (!f) {
      now.innerHTML = '<b class="wx-t wx-none">- -</b><span class="wx-line">no signal</span>';
      hours.innerHTML = ''; trunks.innerHTML = ''; keys.innerHTML = ''; $('.wx-cap').textContent = '';
      $('.wx-at').textContent = refusal || 'No feed named weather is bound yet. Ask AQUA to bind one.';
      $('[data-knob]').hidden = true;
      return;
    }
    const scalars = [], numLists = [], strLists = [];
    if (isItem(r)) {
      for (const [k, v] of Object.entries(r)) {
        if (typeof v === 'number' && Number.isFinite(v)) scalars.push([k, v]);
        else if (typeof v === 'string' || typeof v === 'boolean') scalars.push([k, v]);
        else if (Array.isArray(v) && v.length && v.every((x) => typeof x === 'number')) numLists.push([k, v]);
        else if (Array.isArray(v) && v.length && v.every((x) => typeof x === 'string')) strLists.push([k, v]);
      }
    } else if (r !== undefined && r !== null) scalars.push(['', String(r)]);
    const big = scalars.find(([, v]) => typeof v === 'number');
    const rest = scalars.filter((s) => s !== big).slice(0, 3);
    const unitOf = (k) => (/_c$/.test(k) ? (celsius() ? '°C' : '°F') : words(k));
    now.innerHTML = (big ? `<b class="wx-t">${esc(temp(big[0], big[1]))}</b><span class="wx-u">${esc(unitOf(big[0]))}</span>` : '')
      + rest.map(([k, v]) => `<span class="wx-line">${esc(typeof v === 'number' ? `${words(k)} ${temp(k, v)}` : /^(place|city|name|sky|summary|state|status)$/.test(k) || !k ? v : `${words(k)} ${v}`)}</span>`).join('');
    const list = numLists[0];
    $('.wx-cap').textContent = list ? words(list[0]) : '';
    hours.innerHTML = list ? list[1].slice(0, 4).map((v) => `<li><b>${esc(temp(list[0], v))}${/_c$/.test(list[0]) ? '°' : ''}</b></li>`).join('') : '';
    // A list of names, one of them the result's current one: trunk lines,
    // the current one in service.
    const names = strLists[0];
    const current = names && scalars.find(([, v]) => typeof v === 'string' && names[1].includes(v));
    trunks.innerHTML = names ? names[1].slice(0, 6).map((s) => `<span class="trunk" data-lamp="${current && current[1] === s ? 'green' : 'off'}">${dymo(s)}<span class="lamp"></span></span>`).join('') : '';
    const actions = Array.isArray(f.actions) ? f.actions.filter((a) => isItem(a) && typeof a.name === 'string') : [];
    keys.innerHTML = actions.slice(0, 3).map((a) => `<button class="key sm" data-feedkey="${esc(a.name)}">${esc(text(a.label) || a.name)}</button>`).join('');
    $('.wx-at').textContent = wxWaiting !== null ? 'Asking the feed…' : '';
    const knob = $('[data-knob]');
    knob.hidden = !scalars.concat(numLists).some(([k]) => /_c$/.test(k));
    knob.dataset.unit = celsius() ? 'C' : 'F';
    knob.setAttribute('aria-label', `Units: ${celsius() ? '°C' : '°F'}. Switch`);
  }

  /* ---------- schedules: lever keys and peg counters ---------- */
  const counter = (n) => { const s = String(n).padStart(5, '0'); return `<span class="ctr" aria-label="${n} runs">${s.split('').map((d) => `<span class="dg"><span class="dg-s" style="--d:${d}">0 1 2 3 4 5 6 7 8 9</span></span>`).join('')}</span>`; };
  const pending = new Map();     // schedule id -> the action pressed
  function renderSchedules() {
    const box = $('.seq');
    const list = window.SB.schedules().sort((a, b) => text(a.name).localeCompare(text(b.name)));
    const keep = new Set(list.map((s) => s.schedule_id));
    for (const el of [...box.children]) if (!keep.has(el.dataset.sch)) el.remove();
    $('.schedules .mod-sub').textContent = state.refusals['schedules.changes'] || (list.length ? `${list.filter((s) => s.status === 'active').length} running` : 'none yet');
    list.forEach((s, i) => {
      const id = text(s.schedule_id);
      let el = box.querySelector(`[data-sch="${CSS.escape(id)}"]`);
      if (!el) {
        el = document.createElement('div'); el.className = 'sch'; el.dataset.sch = id;
        el.innerHTML = `<div class="lever-wrap"><span class="lever-l">Hold</span><button class="lever" role="switch"><span class="lever-base"></span><span class="lever-arm"></span></button><span class="lever-l">Run</span></div>
          <div class="sch-name"><span class="dymo"></span><span class="cron"></span></div>
          <div class="ctr-col"><div class="ctr-box"></div><span class="sch-err"></span></div><span class="vfd sch-next"></span>`;
        $('.lever', el).addEventListener('click', () => lever(id, el));
      }
      if (box.children[i] !== el) box.insertBefore(el, box.children[i] || null);
      const name = text(s.name) || componentName(s.reference);
      const active = s.status === 'active';
      const was = pending.get(id);
      if (was && ((was === 'pause' && !active) || (was === 'resume' && active))) { pending.delete(id); delete el.dataset.pending; }
      el.dataset.status = text(s.status);
      const tape = $('.dymo', el); tape.textContent = name; tape.style.setProperty('--tilt', `${tilt(name).toFixed(2)}deg`);
      $('.cron', el).textContent = text(s.cron_expression);
      const lv = $('.lever', el);
      lv.disabled = !(active || s.status === 'paused');
      lv.setAttribute('aria-checked', String(active));
      lv.setAttribute('aria-label', `${name}: ${active ? 'running' : text(s.status) || 'held'}. ${active ? 'Pause' : 'Resume'}`);
      const runs = Number(s.run_count) || 0;
      const cb = $('.ctr-box', el);
      if (cb.dataset.n !== String(runs)) {
        const digits = String(runs).padStart(5, '0');
        if (!cb.firstChild || cb.querySelectorAll('.dg-s').length !== digits.length) cb.innerHTML = counter(runs);
        else digits.split('').forEach((d, j) => cb.querySelectorAll('.dg-s')[j].style.setProperty('--d', d));
        cb.dataset.n = runs; cb.firstChild.setAttribute('aria-label', `${runs} runs`);
      }
      const errors = Number(s.error_count) || 0;
      $('.sch-err', el).textContent = `${errors} error${errors === 1 ? '' : 's'}`;
      $('.sch-err', el).classList.toggle('bad', errors > 0);
      const next = parse(s.next_run_at);
      $('.sch-next', el).textContent = active && next ? rel(s.next_run_at, '—', true) : 'held';
      $('.sch-next', el).title = active ? 'Next run' : `Last run ${rel(s.last_run_at, 'never')}`;
    });
  }
  async function lever(id, el) {
    const held = state.schedules.get(id);
    if (!held) return;
    const s = held.item;
    const action = s.status === 'active' ? 'pause' : 'resume';
    const name = text(s.name) || componentName(s.reference);
    pending.set(id, action); el.dataset.pending = action;
    tell(`${name} · ${action} pressed`);
    const answer = await sdk.press(action === 'pause' ? PAUSE : RESUME, id);
    if (answer && answer.outcome === 'accepted') return;
    pending.delete(id); delete el.dataset.pending;
    tell(answer && answer.outcome === 'refused' ? `${name} · refused (${text(answer.reason) || 'no reason'})` : `${name} · not pressed: tap the lever again`, 6000);
  }

  /* ---------- runs: the ticket printer ---------- */
  const TYPE = { catalyst: 'CAT', formula: 'FRM', agent: 'AGT', tincture: 'TNC' };
  let seenRuns = null;
  function renderRuns() {
    const runs = state.runs;
    const failed = runs.filter((r) => r.kind === 'failed').length;
    $('.runs .mod-sub').textContent = state.refusals['runs.changes'] || (failed ? `${failed} failed` : runs.length ? `last ${runs.length}` : 'none yet');
    // A ticket prints as it happens; the current state was already printed.
    const fresh = seenRuns ? runs.filter((r) => !r.refresh && !seenRuns.has(`${r.execution_id}${r.kind}`)) : [];
    $('.paper').innerHTML = runs.slice(0, 6).map((r) => {
      const name = componentName(r.reference) || text(r.reference);
      const what = r.kind === 'started' ? 'running' : r.kind === 'completed' ? `ok ${secs(r.duration_ms)}` : r.kind === 'failed' ? 'failed' : 'cancelled';
      return `<li class="tk ${esc(text(r.kind))}${fresh.includes(r) ? ' fresh' : ''}">
        <span class="tk-t">${TYPE[r.component_type] || ''}</span><span class="tk-n">${esc(name)}</span><span class="tk-d">${esc(what)}</span>
        ${r.kind === 'failed' ? `<span class="tk-why">${esc(cause(r.error))}</span><button class="key sm tk-open" data-runs>Look</button>` : ''}</li>`;
    }).join('') || '<li class="tk-none">No runs yet. A run of any component prints here as it happens.</li>';
    seenRuns = new Set(runs.map((r) => `${r.execution_id}${r.kind}`));
  }

  /* ---------- vault and crew: annunciator windows ---------- */
  function renderVault() {
    const list = window.SB.vault().sort((a, b) => text(a.name).localeCompare(text(b.name)));
    const refusal = state.refusals['vault.changes'];
    const at = state.readAt['vault.changes'];
    $('.vault .mod-sub').textContent = refusal || (at ? hm(at) : '');
    $('.vault .mod-sub').title = at ? `As of ${hm(at)}` : '';
    $('.vault-annun').innerHTML = list.map((v) => {
      const fine = v.status === 'fine';
      const say = fine ? 'Fine' : 'Re-authorise';
      return `<button class="win" data-lamp="${fine ? 'green' : 'red'}" data-vault aria-label="${esc(v.name)}: ${say}. Open the vault"><span class="win-n">${esc(v.name)}</span><span class="win-s">${say}</span></button>`;
    }).join('') || (refusal ? '' : '<p class="job-none">Nothing stored yet</p>');
  }
  function renderCrew() {
    const jobs = window.SB.activity().sort((a, b) => text(a.since).localeCompare(text(b.since)));
    const at = state.readAt['activity.changes'];
    $('.crew .mod-sub').textContent = state.refusals['activity.changes'] || (jobs.length ? `${jobs.length} at work` : at ? hm(at) : '');
    $('.crew .mod-sub').title = at ? `As of ${hm(at)}` : '';
    $('.jobs').innerHTML = jobs.slice(0, 3).map((j) => `<div class="job" data-lamp="white"><span class="lamp"></span><span class="job-who">${esc(text(j.member))}</span><span class="job-since">for ${esc(text(j.asked_by))} · ${esc(rel(j.since))}</span><span class="job-t">${esc(text(j.status).replace(/_/g, ' '))}</span></div>`).join('')
      || '<p class="job-none">No crew job running</p>';
  }

  /* ---------- the rack: parts on and off, and their order ---------- */
  // Each write names whole widget entries: the fields the board keeps.
  function entryWith(id, change) {
    const e = entry(id);
    const out = { on: e.on !== false, order: orderOf(id) };
    if (isItem(e.rect)) out.rect = e.rect;
    if (id === 'weather' && (e.units === 'c' || e.units === 'f')) out.units = e.units;
    return { ...out, ...change };
  }
  async function save(widgetsDoc, done) {
    const answer = await sdk.prefs({ widgets: widgetsDoc });
    const outcome = answer && answer.outcome;
    if (outcome === 'saved') tell(`${done} · saved`);
    else if (outcome === 'stale') tell('Another screen changed the rack first · tap again', 6000);
    else if (outcome === 'refused') tell(`Not saved (${text(answer.reason) || 'refused'})`, 6000);
    else tell('Not saved: tap again', 6000);
  }
  function applyPrefs() {
    for (const id of Object.keys(PARTS)) {
      const el = $(`[data-part="${id}"]`);
      el.hidden = !isOn(id); el.style.order = orderOf(id);
    }
    const off = Object.keys(PARTS).filter((id) => !isOn(id));
    $('.spares-list').innerHTML = off.length ? off.map((id) => `<button class="key spare" data-fit="${id}">Fit ${PARTS[id].title}</button>`).join('') : '<span class="spares-none">Every part is fitted</span>';
    for (const z of ['field', 'meters', 'shelf']) $(`[data-zone="${z}"]`).dataset.count = Object.keys(PARTS).filter((id) => PARTS[id].zone === z && isOn(id)).length;
    requestAnimationFrame(() => window.Cords.fit());
  }
  function rackBars() {
    for (const id of Object.keys(PARTS)) {
      const el = $(`[data-part="${id}"]`);
      if (el.querySelector(':scope > .rack-bar')) continue;
      const bar = document.createElement('div'); bar.className = 'rack-bar'; bar.dataset.for = id;
      bar.innerHTML = `<button class="key sm" data-move="-1" aria-label="Move ${PARTS[id].title} earlier">◂</button><button class="key sm" data-move="1" aria-label="Move ${PARTS[id].title} later">▸</button><button class="key sm pull" data-pull aria-label="Turn ${PARTS[id].title} off">Pull</button>`;
      el.prepend(bar);
    }
  }
  function zoneIds(zone) {
    return Object.keys(PARTS).filter((k) => PARTS[k].zone === zone && isOn(k)).sort((a, b) => orderOf(a) - orderOf(b));
  }
  function move(id, dir) {
    const ids = zoneIds(PARTS[id].zone);
    const i = ids.indexOf(id), j = i + dir;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    save(Object.fromEntries(ids.map((k, n) => [k, entryWith(k, { order: n })])), `${PARTS[id].title} moved`);
  }
  function setRack(on) {
    drop(true);
    root.dataset.rack = on ? 'on' : 'off';
    $('.rack-key').setAttribute('aria-pressed', String(on));
    $('.rack-key').textContent = on ? 'Done' : 'Rack';
    $('.spares').hidden = !on;
    if (on) { rackBars(); tell('Rack open · pull, fit or move parts', 60000); } else { note = null; summary(); }
    requestAnimationFrame(() => window.Cords.wake());
  }

  /* ---------- taps ---------- */
  function onClick(e) {
    const t = e.target;
    if (t.closest('.rack-key')) { setRack(root.dataset.rack !== 'on'); return; }
    if (t.closest('[data-rackdone]')) { setRack(false); return; }
    const bar = t.closest('.rack-bar');
    if (bar && t.closest('[data-move]')) { move(bar.dataset.for, Number(t.closest('[data-move]').dataset.move)); return; }
    if (bar && t.closest('[data-pull]')) { const id = bar.dataset.for; save({ [id]: entryWith(id, { on: false }) }, `${PARTS[id].title} pulled`); return; }
    const fit = t.closest('[data-fit]');
    if (fit) {
      const id = fit.dataset.fit;
      const last = zoneIds(PARTS[id].zone).reduce((m, k) => Math.max(m, orderOf(k)), -1);
      save({ [id]: entryWith(id, { on: true, order: last + 1 }) }, `${PARTS[id].title} fitted`);
      return;
    }
    const ask = t.closest('.askjack');
    if (ask) {
      const part = ask.dataset.ask;
      lift(ask, $('.jack', ask), { id: `part:${part}`, widget: part, module: true, name: (part === 'weather' && $('.weather h2').textContent) || PARTS[part].title, page: PARTS[part].page, targets: ['aqua', 'settings'], primary: 'aqua' });
      return;
    }
    const pos = t.closest('.pos');
    if (pos) { patch(pos.dataset.dest); return; }
    if (t.closest('[data-knob]')) {
      const units = celsius() ? 'f' : 'c';
      save({ weather: entryWith('weather', { units }) }, `Units ${units === 'f' ? '°F' : '°C'}`);
      return;
    }
    const feedKey = t.closest('[data-feedkey]');
    if (feedKey && state.feeds.weather) {
      const f = state.feeds.weather;
      wxWaiting = f.revision;
      sdk.press(f.binding, feedKey.dataset.feedkey);
      window.SB.readSoon('feed:weather');
      tell(`${feedKey.textContent} pressed`);
      renderWeather();
      return;
    }
    if (t.closest('[data-vault]')) { sdk.settings('vault'); tell('Vault → settings'); return; }
    if (t.closest('[data-runs]')) { sdk.settings('executions'); tell('Runs → settings'); return; }
    if (hand && !t.closest('.line,.pos,.askjack')) drop();
  }

  /* ---------- the shell's own facts: appearance, posture, what covers the page ---------- */
  function applyAppearance() {
    const a = state.appearance;
    html.dataset.theme = a.mode;
    if (a.accent && /^#[0-9a-f]{3,8}$/i.test(a.accent)) html.style.setProperty('--cord', a.accent); else html.style.removeProperty('--cord');
    const sa = isItem(a.safe_areas) ? a.safe_areas : {};
    const px = (k) => (Number.isFinite(sa[k]) ? sa[k] : 0);
    root.style.padding = `calc(var(--pad) + ${px('top')}px) calc(var(--pad) + ${px('right')}px) calc(var(--pad) + ${px('bottom')}px) calc(var(--pad) + ${px('left')}px)`;
    $('.badge-place').textContent = state.person || '';
    $('.badge-place').hidden = !state.person;
  }
  function applyPosture() {
    html.dataset.posture = state.posture || 'desk';
    html.dataset.compact = state.posture === 'hand' || innerWidth <= 640 ? 'on' : 'off';
  }
  // A window over the right or bottom of the page at the desk: the board
  // narrows to the part it leaves uncovered, and the page scrolls.
  function fitCovered() {
    const W = innerWidth, H = innerHeight;
    let r = 0, b = 0;
    for (const c of state.covered) {
      if (c.x + c.width >= W - 2 && c.height > H * 0.5) r = Math.max(r, W - c.x);
      if (c.y + c.height >= H - 2 && c.width > W * 0.5) b = Math.max(b, H - c.y);
    }
    root.style.setProperty('--covered-r', `${r}px`); root.style.setProperty('--covered-b', `${b}px`);
    root.dataset.narrow = r > W * 0.3 ? 'on' : 'off';
  }
  let clock = 0;
  function applyLive() {
    const live = state.live && !document.hidden;
    html.dataset.live = live ? 'on' : 'off';
    window.Cords.freeze(!live);
    clearInterval(clock);
    if (live) { tick(); clock = setInterval(tick, 1000); }
  }

  /* ---------- drawing what changed ---------- */
  function render(kinds) {
    const all = kinds.has('all');
    const has = (...k) => all || k.some((x) => kinds.has(x));
    if (has('desktop')) { applyAppearance(); applyPrefs(); }
    if (has('posture')) applyPosture();
    if (has('covered', 'posture')) fitCovered();
    if (has('state')) applyLive();
    if (has('attention', 'threads', 'components', 'runs', 'schedules', 'installed', 'refusals')) renderLines();
    if (has('feeds', 'refusals', 'desktop')) {
      const f = state.feeds.weather;
      if (wxWaiting !== null && f && f.revision !== wxWaiting) { wxWaiting = null; tell('Weather · new reading'); }
      renderWeather();
    }
    if (has('schedules', 'refusals')) renderSchedules();
    if (has('runs', 'refusals')) renderRuns();
    if (has('vault', 'refusals')) renderVault();
    if (has('activity', 'refusals')) renderCrew();
    summary();
    if (has('desktop', 'covered', 'posture', 'installed', 'threads', 'components', 'attention')) requestAnimationFrame(() => window.Cords.fit());
  }

  window.Board = {
    mount(api, el) {
      sdk = api; root = el;
      skeleton();
      root.addEventListener('click', onClick);
      addEventListener('keydown', (e) => { if (e.key === 'Escape') drop(); });
      addEventListener('resize', () => { applyPosture(); fitCovered(); renderLines(); window.Cords.fit(); });
      document.addEventListener('visibilitychange', applyLive);
      document.fonts && document.fonts.ready.then(() => window.Cords.fit());
      render(new Set(['all']));
    },
    render,
  };
})();

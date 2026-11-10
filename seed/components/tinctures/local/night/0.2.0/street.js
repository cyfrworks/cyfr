/* The street in the browser: the streams it keeps open, the taps, the action
 * plate and the breaker box. Everything it reads comes through window.cyfr,
 * which CYFR puts in the page before this script; every verb it sends goes
 * on the person's own tap. */
(function () {
  'use strict';
  const N = window.Night;
  const sdk = window.cyfr;
  const $ = (q, el) => (el || document).querySelector(q);
  const $$ = (q, el) => [...(el || document).querySelectorAll(q)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const OUT_MS = 1400;
  // Pauses before opening a stream again, growing while opens fail.
  const RETRY_MS = [2000, 5000, 15000, 60000];

  const state = N.EMPTY();
  const ui = { now: Date.now(), going: {}, gone: {}, working: {}, fuse: false, note: null, selected: null, live: true };
  const els = {};

  // ---------- what the shell tells the page ----------
  function takeDesktop(d) {
    if (!N.isItem(d)) return;
    if (N.isItem(d.prefs) && N.isItem(d.prefs.document)) state.prefs = d.prefs.document;
    if (N.isItem(d.appearance)) {
      state.appearance = d.appearance;
      if (/^#[0-9a-f]{6}$/i.test(N.text(d.appearance.accent))) document.documentElement.style.setProperty('--accent', d.appearance.accent);
      const sa = N.isItem(d.appearance.safe_areas) ? d.appearance.safe_areas : {};
      for (const side of ['top', 'right', 'bottom', 'left']) document.documentElement.style.setProperty('--safe-' + side, (Number(sa[side]) || 0) + 'px');
    }
    if (N.isItem(d.person)) state.person = d.person;
  }
  function takeInstalled(list) {
    state.installed = Array.isArray(list) ? list.filter((a) => N.isItem(a) && typeof a.ref === 'string' && typeof a.name === 'string')
      .map((a) => ({ ref: a.ref, name: a.name, icon: typeof a.icon === 'string' && a.icon ? a.icon : null, open: a.open === true })) : [];
  }
  function setCovered(list) {
    const rects = Array.isArray(list) ? list.filter(N.isItem) : [];
    for (const el of $$('.part')) {
      const r = el.getBoundingClientRect();
      const hit = rects.some((c) => c.x < r.right && c.x + c.width > r.left && c.y < r.bottom && c.y + c.height > r.top);
      if (hit) el.dataset.covered = '1'; else delete el.dataset.covered;
    }
    ui.covered = rects;
  }
  function setLive(v) {
    ui.live = v === 'live';
    els.root.classList.toggle('is-frozen', !ui.live);
    if (window.Scene) Scene.setLive(ui.live);
  }

  // ---------- every stream the street reads, open from the start ----------
  // Each declared stream opens once at start and stays open whatever part
  // is on. The SDK opens an opened stream again by itself after a lost
  // connection; the street opens one again only when its first open got no
  // answer, or when the endpoint ended it with no refusal.
  const followers = new Map();
  function follow(key) {
    const [name, subject] = key.startsWith('feed:') ? ['feed.results', key.slice(5)] : [key, null];
    const f = { handle: null, opening: false, tries: 0, timer: 0, first: null };
    const pause = () => RETRY_MS[Math.min(f.tries++, RETRY_MS.length - 1)];
    function open() {
      if (f.opening) return f.first;
      f.opening = true;
      clearTimeout(f.timer);
      N.opening(state, key);
      f.first = sdk.stream(name, subject, (ev) => heard(key, f, ev)).then((handle) => {
        f.opening = false; f.handle = handle;
        // Ended with no refusal (as at the grant's day-long bound): open it again.
        handle.closed.catch(() => {}).then(() => { if (f.handle === handle && handle.state === 'ended') f.timer = setTimeout(open, pause()); });
      }, (error) => {
        f.opening = false;
        const code = error && error.code;
        if (code === 'unavailable') {
          const wait = pause();
          changed(() => { N.refused(state, key, code, Date.now() + wait); return 'state'; });
          f.timer = setTimeout(open, wait);
        } else changed(() => { N.refused(state, key, code); return 'picture'; });
      });
      return f.first;
    }
    followers.set(key, f);
    open();
  }
  function heard(key, f, ev) {
    if (!N.isItem(ev)) return;
    if (ev.event === 'snapshot') f.tries = 0;
    changed(() => {
      const moved = N.hear(state, key, ev);
      if (moved === 'change' && key === 'runs.changes' && ev.data.kind === 'completed') landed('board');
      if (moved === 'change' && key.startsWith('feed:')) { ui.working[key.slice(5)] = false; landed(key.slice(5)); }
      return moved;
    });
  }

  // ---------- a change: hold it, notice what switched off, draw ----------
  // `fn` answers 'picture' when a picture replaced what was held: what it
  // no longer names is simply gone, and only a live answer switches a light off.
  let shownIds = new Map();
  function changed(fn) {
    const quiet = fn() === 'picture';
    const now = N.waiting(state, null);
    const ids = new Map(now.map((w) => [w.id, w]));
    for (const [id, w] of shownIds) {
      if (ids.has(id) || ui.going[id]) continue;
      if (ui.selected && ui.selected.att === id) closePlate();
      if (quiet) continue;
      ui.going[id] = Date.now(); ui.gone[id] = w;
      setTimeout(() => { delete ui.going[id]; delete ui.gone[id]; schedule(); }, reduced ? 200 : OUT_MS);
    }
    shownIds = ids;
    schedule();
  }
  let pending = 0;
  function schedule() { if (!pending) pending = requestAnimationFrame(() => { pending = 0; render(); }); }

  function landed(part) {
    const el = $('[data-part="' + part + '"]');
    const flash = () => { if (!el || reduced) return; el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash'); };
    if (!(window.Scene && Scene.pulse(part, '#cfeaff', flash))) flash();
  }

  // ---------- draw ----------
  function render(opts) {
    const before = opts && opts.flip ? rects() : null;
    ui.now = Date.now();
    const m = N.renderStreet(state, ui);
    els.header.innerHTML = m.header;
    els.wall.innerHTML = m.wall;
    els.level.innerHTML = m.level;
    els.puddle.innerHTML = m.puddle;
    els.puddle.classList.remove('puddle--tight', 'puddle--scroll');
    for (const el of $$('[data-light="out"]')) {
      const at = ui.going[el.dataset.att];
      if (at) el.style.setProperty('--out-delay', -(Date.now() - at) + 'ms');
    }
    if (ui.selected) {
      const el = $('[data-target="' + cssq(ui.selected.ref) + '"]');
      if (el) el.setAttribute('aria-expanded', 'true');
    }
    if (ui.fuse) els.fuse.innerHTML = N.renderFusebox(state, ui);
    fitBoard();
    if (before) flip(before);
    if (ui.covered) setCovered(ui.covered);
    if (window.Scene) Scene.relayout();
    requestAnimationFrame(placeRipples);
    if (before) setTimeout(placeRipples, 460);
    els.root.dataset.waiting = String(m.list.filter((w) => w.light !== 'out').length);
  }
  // The board shows the rows it has room for at full height: the newest
  // runs that wait on nothing go first, then the later schedules, then the
  // later failures, keeping one of each; its last line counts the failures
  // it hid, which the puddle still lists.
  function fitBoard() {
    const board = $('.board');
    if (!board) return;
    const ranList = $('.rows--ran', board);
    const ran = ranList ? $$(':scope > li', ranList) : [];
    const nextList = $$('.rows', board).find((ul) => ul !== ranList);
    const next = nextList ? $$(':scope > li', nextList) : [];
    const more = $('.board__more', board);
    const total = ranList ? Number(ranList.dataset.litTotal) || 0 : 0;
    const shown = (list) => list.filter((li) => !li.classList.contains('row--unfit'));
    const count = () => {
      const hidden = total - shown(ran).filter((li) => li.dataset.lit).length;
      more.hidden = hidden <= 0;
      more.textContent = hidden > 0 ? 'and ' + hidden + ' more failed, in the puddle below' : '';
    };
    count();
    while (board.scrollHeight > board.clientHeight + 1) {
      const r = shown(ran), n = shown(next);
      const victim = (r.length > 1 && [...r].reverse().find((li) => !li.dataset.lit)) || (n.length > 1 && n[n.length - 1]) || (r.length > 1 && r[r.length - 1]);
      if (!victim) break;
      victim.classList.add('row--unfit');
      count();
    }
  }
  const cssq = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  // Each reflection's label sits under its sign; labels push apart so none overlap.
  function placeRipples() {
    if (innerWidth < 600) return;
    const pb = els.puddle.getBoundingClientRect();
    const items = $$('.ripples li', els.puddle).map((li) => {
      const sign = $('[data-target="' + cssq($('.ripple', li).dataset.ref) + '"]');
      const vis = sign && sign.offsetParent !== null;
      const r = vis ? sign.getBoundingClientRect() : null;
      return { li, w: li.offsetWidth, x: vis ? r.left + r.width / 2 - pb.left : pb.width + 999 };
    }).sort((a, b) => a.x - b.x);
    const gap = 8, m = 12;
    let edge = m;
    for (const it of items) { it.left = Math.max(edge, it.x - it.w / 2); edge = it.left + it.w + gap; }
    let over = edge - gap - (pb.width - m);
    for (let i = items.length - 1; i >= 0 && over > 0; i--) {
      const it = items[i], limit = i ? items[i - 1].left + items[i - 1].w + gap : m;
      const room = Math.min(over, it.left - limit);
      if (room > 0) { for (let j = i; j < items.length; j++) items[j].left -= room; over -= room; }
    }
    for (const it of items) { it.li.style.left = it.left + 'px'; it.li.style.transform = 'none'; }
    // Too many to stand under their signs: drop the times, then let the row scroll.
    const over2 = edge - gap - (pb.width - m);
    if (over2 > 0 && !els.puddle.classList.contains('puddle--tight')) { els.puddle.classList.add('puddle--tight'); placeRipples(); return; }
    els.puddle.classList.toggle('puddle--scroll', over2 > 0);
  }
  function rects() { const r = {}; for (const el of $$('.part')) r[el.dataset.part] = el.getBoundingClientRect(); return r; }
  function flip(before) {
    if (reduced) return;
    for (const el of $$('.part')) {
      const b = before[el.dataset.part];
      if (!b) { el.classList.add('strike'); setTimeout(() => el.classList.remove('strike'), 1100); continue; }
      const a = el.getBoundingClientRect();
      const dx = b.left - a.left, dy = b.top - a.top;
      if (!dx && !dy) continue;
      el.animate([{ transform: 'translate(' + dx + 'px,' + dy + 'px)' }, { transform: 'none' }], { duration: 420, easing: 'cubic-bezier(.2,.8,.2,1)' });
    }
  }

  // ---------- what a tap on each sign offers ----------
  function aboutTarget(ref) {
    const C = N.clock(state);
    const list = N.waiting(state, null);
    const lit = N.litTable(list).get(ref);
    const i = ref.indexOf(':');
    const kind = i < 0 ? ref : ref.slice(0, i), id = i < 0 ? '' : ref.slice(i + 1);
    const out = { ref, hue: lit ? lit.hue : null, att: lit ? lit.id : null, kind: lit ? lit.word + (lit.since ? ' · since ' + C.hm(lit.since) : '') : '', title: '', lines: [], acts: [] };
    const ask = (widget) => out.acts.push({ label: 'Ask AQUA', act: 'ask', widget });
    const page = (label, key, primary) => out.acts.push({ label, act: 'settings', page: key, primary });
    // Where a waiting item is acted on: the page its destination names.
    const dest = lit && lit.item && N.isItem(lit.item.destination) && lit.item.destination.kind === 'page' ? N.text(lit.item.destination.page) : '';
    if (kind === 'thread') {
      const t = state.threads.get(id) || {};
      const last = N.time(t.last_activity);
      const unread = Number.isInteger(t.unread) && t.unread > 0 ? t.unread : 0;
      out.title = N.text(t.title) || (lit ? lit.label : 'Thread');
      out.lines.push(t.kind === 'own' ? 'Your thread with AQUA' : Array.isArray(t.people) ? t.people.length + (t.people.length === 1 ? ' person' : ' people') : '', [last ? 'last activity ' + C.when(last, Date.now()) : '', unread ? unread + ' unread' : ''].filter(Boolean).join(' · '));
      if (lit) out.lines.push('An approval waits for you in AQUA.');
      // An approval opens where it waits, a shared thread the chat and an
      // own thread AQUA's panel; neither opens at the thread itself.
      if (lit) page('Open the approval', dest || 'aqua', true);
      else if (t.kind === 'shared') page('Open in chat', 'chat', true);
      else if (t.kind === 'own') page('Open in AQUA', 'aqua', true);
      ask('threads');
    } else if (kind === 'schedule') {
      const x = state.schedules.get(id);
      out.title = x ? N.text(x.name) : lit ? lit.label : 'Schedule';
      if (x) {
        const next = N.time(x.next_run_at), last = N.time(x.last_run_at);
        out.lines.push(N.text(x.cron_expression) + ' · ' + N.words(x.status), x.status === 'paused' ? (last ? 'last ran ' + C.when(last, Date.now()) : '') : next ? 'next ' + C.when(next, Date.now()) : '', (Number(x.run_count) || 0) + ' runs · ' + (Number(x.error_count) || 0) + ' errors');
        if (x.status === 'active') out.acts.push({ label: 'Pause', act: 'press', control: 'pause-schedule', value: id, primary: true });
        if (x.status === 'paused') out.acts.push({ label: 'Resume', act: 'press', control: 'resume-schedule', value: id, primary: true });
      }
      if (lit) out.lines.push('Its last run failed.');
      page('Open schedules', dest || 'schedules', !x);
      ask('board');
    } else if (kind === 'failed' || kind === 'run') {
      // A failure that waits names its run by the destination's ref.
      const runId = kind === 'run' ? id : lit && N.isItem(lit.item.destination) ? N.text(lit.item.destination.ref) : '';
      const item = state.runs.get(runId) || null;
      const reference = item ? N.text(item.reference) : id;
      const started = item ? N.time(item.started_at) : null, ended = item ? N.time(item.ended_at) : null;
      out.title = N.compName(reference) + (started ? ' at ' + C.hm(started) : lit && lit.since ? ' at ' + C.hm(lit.since) : '');
      const err = item && N.isItem(item.error) ? item.error : null;
      out.lines.push(reference, item ? (item.kind === 'failed' ? (err ? N.words(err.class) + ' · ' + N.words(err.cause) : 'failed') : item.kind === 'started' ? 'running' + (started ? ' since ' + C.hm(started) : '') : item.kind === 'completed' ? 'finished' + (typeof item.duration_ms === 'number' ? ' in ' + (item.duration_ms / 1000).toFixed(1) + ' s' : '') : N.words(item.kind)) + (ended ? ' · ended ' + C.hm(ended) : '') : 'failed');
      // Only a failed root run the street holds runs again: the shell checks the id against the runs it reads.
      if (item && item.kind === 'failed' && !item.parent_execution_id) out.acts.push({ label: 'Retry', act: 'press', control: 'retry-run', value: runId, primary: true });
      page('Open runs', dest || 'executions', !out.acts.length);
      ask('board');
    } else if (kind === 'feed') {
      const f = N.feedOf(state, id);
      if (f) {
        const acts = Array.isArray(f.actions) ? f.actions.filter((a) => N.isItem(a) && typeof a.name === 'string').slice(0, 3) : [];
        if (id === 'weather') { const w = N.weatherOf(f); out.title = 'Weather' + (w.place ? ' in ' + w.place : ''); out.lines.push([w.temp !== undefined ? Math.round(w.temp) + '°' : '', w.sky].filter(Boolean).join(' · ')); }
        else { const r = N.isItem(f.result) ? f.result : {}; out.title = N.text(f.label) || 'VPN'; out.lines.push([N.text(r.state || r.status), N.text(r.server)].filter(Boolean).join(' · ')); }
        const at = N.time(f.at);
        if (at) out.lines.push('updated ' + C.when(at, Date.now()));
        for (const a of acts) out.acts.push({ label: N.text(a.label) || a.name, act: 'feed', binding: f.binding, action: a.name, feed: id, primary: out.acts.length === 0 });
      } else { out.title = id === 'weather' ? 'Weather' : 'VPN'; out.lines.push('No ' + (id === 'weather' ? 'weather' : 'VPN') + ' feed is bound yet.'); }
      ask(id);
    } else if (kind === 'crew') {
      out.title = 'Crew';
      const jobs = [...state.activity.values()];
      if (!jobs.length) out.lines.push('No one is at work.');
      for (const j of jobs.slice(0, 4)) { const at = N.time(j.since); out.lines.push(N.text(j.member) + ' · ' + (N.text(j.title) || N.words(j.status)) + (j.asked_by ? ' · for ' + N.text(j.asked_by) : '') + (at ? ' · since ' + C.hm(at) : '')); }
      ask('crew');
    } else if (kind === 'app') {
      const app = state.installed.find((a) => N.versionless(a.ref) === id);
      const c = state.components.get(id);
      out.title = app ? app.name : N.compName(id);
      out.lines.push('app' + (c && c.version ? ' ' + N.text(c.version) : '') + (app && app.open ? ' · open' : ''), lit ? 'It waits for your grant.' : '');
      if (lit) out.acts.push({ label: 'Review the grant', act: 'grant', ref: id, primary: true });
      if (app) out.acts.push({ label: 'Open ' + app.name, act: 'open', app: app.ref, primary: !lit });
      ask('apps');
    } else if (kind === 'offer') {
      const o = state.files.get(id), a = state.attention.get(id);
      out.title = o ? N.text(o.name) : a ? N.text(a.label) : 'A file';
      const at = N.time(o ? o.changed_at : a && a.since);
      out.lines.push('offered to you' + (o && N.text(o.from) ? ' by ' + N.text(o.from) : '') + (at ? ' at ' + C.hm(at) : ''));
      page('Open files', dest || 'files', true);
      ask('files');
    } else if (kind === 'file') {
      const f = state.files.get(id) || {};
      const at = N.time(f.changed_at);
      out.title = N.text(f.name) || id;
      out.lines.push([N.text(f.type), at ? 'changed ' + C.when(at, Date.now()) : ''].filter(Boolean).join(' · '));
      page('Open files', 'files', true);
      ask('files');
    } else if (kind === 'cyfr') {
      const y = N.sysOf(state);
      const st = y ? N.storage(y) : null;
      out.title = 'CYFR' + (y && N.text(y.version) ? ' ' + N.text(y.version) : '');
      if (y) out.lines.push(N.systemLines(y).map((l) => l[1]).concat(st ? [st.text + ' used'] : []).join(' · '), y.update_available === true ? 'An update is available.' : '');
      if (lit) out.lines.push('CYFR asks you to confirm ' + lit.label + ': its own prompt shows it.');
      page('Open settings', 'settings', true);
      ask('cyfr');
    } else if (kind === 'vault') {
      const v = state.vault.get(id) || {};
      out.title = id;
      out.lines.push(N.words(v.type) + ' · ' + (v.status === 'fine' ? 'fine' : 'needs re-authorisation'));
      page(v.status === 'fine' ? 'Open the vault' : 'Re-authorise in the vault', 'vault', true);
      ask('vault');
    }
    out.lines = out.lines.filter(Boolean);
    return out;
  }

  // ---------- the plate: a sign's actions, hung beside it ----------
  function openPlate(ref, anchor) {
    const info = aboutTarget(ref);
    // `busy`: the act whose press waits for its answer; `note`: what the last answer said.
    ui.selected = { ref, att: info.att, info, busy: -1, note: '' };
    const p = els.plate;
    p.style.setProperty('--hue', info.hue || 'var(--accent)');
    p.dataset.lit = info.hue ? '1' : '';
    drawPlate();
    p.hidden = false;
    placePlate(anchor);
    $$('[aria-expanded="true"][data-target]').forEach((e) => e.removeAttribute('aria-expanded'));
    anchor.setAttribute('aria-expanded', 'true');
    const first = $('.btn', p); if (first) first.focus({ preventScroll: true });
  }
  // A press waiting for its answer chases lights round its button, which takes no second tap.
  function drawPlate() {
    const { info, busy, note } = ui.selected;
    els.plate.innerHTML = '<div class="plate__in">' +
      (info.kind ? '<p class="plate__kind">' + N.esc(info.kind) + '</p>' : '') +
      '<h2 id="plate-title">' + N.esc(info.title) + '</h2>' + info.lines.map((l) => '<p class="meta">' + N.esc(l) + '</p>').join('') +
      '<p class="plate__note" role="status">' + N.esc(note) + '</p>' +
      '<div class="plate__acts">' + info.acts.map((a, i) => '<button class="btn' + (a.primary ? ' btn--go' : '') + (busy === i ? ' is-working' : '') + '" data-plate="' + i + '"' + (busy === i ? ' disabled aria-busy="true"' : '') + '>' + (a.act === 'ask' ? '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3c3 4 6 7 6 11a6 6 0 0 1-12 0c0-4 3-7 6-11z"/></svg>' : '') + N.esc(a.label) + (busy === i ? N.chase() : '') + '</button>').join('') + '</div>' +
      '<button class="plate__x" data-act="plate-close" aria-label="Close">×</button></div>';
    els.plate._acts = info.acts;
  }
  function placePlate(anchor) {
    const p = els.plate, box = els.root.getBoundingClientRect(), r = anchor.getBoundingClientRect();
    if (innerWidth < 600) { p.style.left = ''; p.style.top = ''; p.classList.add('plate--sheet'); return; }
    p.classList.remove('plate--sheet');
    const w = p.offsetWidth, h = p.offsetHeight, m = 10;
    let x = r.left + r.width / 2 - w / 2, y = r.bottom + 8;
    if (y + h > box.bottom - m) y = r.top - h - 8;
    if (y < box.top + m) { y = Math.max(box.top + m, Math.min(box.bottom - h - m, r.top)); x = r.right + 10; if (x + w > box.right - m) x = r.left - w - 10; }
    x = Math.max(box.left + m, Math.min(box.right - w - m, x));
    p.style.left = x + 'px'; p.style.top = y + 'px';
  }
  function closePlate() {
    els.plate.hidden = true; ui.selected = null;
    $$('[aria-expanded="true"][data-target]').forEach((e) => e.removeAttribute('aria-expanded'));
  }
  const SPENT = 'That tap was not taken. Tap again.';
  // A tap within a few seconds of the last one is dropped (`too_soon`).
  const TOO_SOON = 'Too soon after your last tap. Wait a moment, then tap again.';
  const notTaken = (answer) => (answer.reason === 'too_soon' ? TOO_SOON : SPENT);
  // What a Retry's refusal says, by its class.
  const SOON = 'CYFR cannot run it now. Try again shortly.';
  const RETRY_REFUSED = {
    conflict: 'This run cannot run again: only a failed run a schedule or a feed started can, under the grant it ran with.',
    invalid_argument: 'It is no longer among the latest runs.',
    not_found: 'That run is gone.',
    forbidden: 'That run is not yours to run again.',
    unavailable: SOON, rate_limited: SOON, timeout: SOON,
    uncertain: 'No answer came. Look at your runs before trying again.',
  };
  function answered(control, answer) {
    if (answer.outcome === 'cancelled') return answer.reason === 'too_soon' ? TOO_SOON : control === 'retry-run' ? 'That tap was not taken, so nothing ran.' : SPENT;
    if (control !== 'retry-run') return 'Refused · ' + N.words(answer.reason || 'refused');
    return answer.outcome === 'accepted' ? 'Running it again.' : RETRY_REFUSED[answer.reason] || 'It could not be run again.';
  }
  // One tap, one verb: each act sends exactly one of the shell's verbs.
  function runPlateAct(a) {
    if (a.act === 'ask') { sdk.ask(a.widget); closePlate(); }
    else if (a.act === 'settings') { sdk.settings(a.page); closePlate(); }
    else if (a.act === 'open') { sdk.open(a.app); closePlate(); }
    else if (a.act === 'grant') { sdk.grant(a.ref); closePlate(); }
    else if (a.act === 'feed') { sdk.press(a.binding, a.action); ui.working[a.feed] = true; schedule(); closePlate(); }
    else if (a.act === 'press') {
      const sel = ui.selected;
      if (!sel || sel.busy >= 0) return;
      sel.busy = sel.info.acts.indexOf(a); sel.note = '';
      drawPlate();
      sdk.press(a.control, a.value).then((answer) => {
        if (ui.selected !== sel) return;
        sel.busy = -1;
        // A pause or resume shows on the board; a retry says so and stays to be read.
        if (answer.outcome === 'accepted' && a.control !== 'retry-run') return closePlate();
        sel.note = answered(a.control, answer);
        drawPlate();
        const again = $('[data-plate="' + sel.info.acts.indexOf(a) + '"]', els.plate); if (again) again.focus({ preventScroll: true });
      });
    }
  }

  // ---------- the breaker box: which parts are on, and where ----------
  function writePrefs(doc, after) {
    ui.note = null;
    sdk.prefs(doc).then((answer) => {
      if (N.isItem(answer.document)) state.prefs = answer.document;
      if (answer.outcome === 'stale') ui.note = 'Another screen changed your parts first. Flip it again.';
      else if (answer.outcome === 'refused') ui.note = 'Not kept · ' + N.words(answer.reason || 'refused');
      else if (answer.outcome === 'cancelled') ui.note = notTaken(answer);
      render({ flip: true });
      if (after) after();
    });
  }
  function togglePart(id) {
    const doc = N.flipDoc(state.prefs, id);
    const el = $('[data-part="' + id + '"]');
    if (!doc.widgets[id].on && el && !reduced) el.classList.add('cut');
    writePrefs(doc, () => refocus('part-toggle', id));
  }
  function movePart(id, dir) {
    const doc = N.moveDoc(state.prefs, id, dir);
    if (doc) writePrefs(doc, () => refocus('part-move', id, dir));
  }
  function refocus(act, id, dir) {
    const q = '[data-act="' + act + '"][data-part="' + id + '"]' + (dir ? '[data-dir="' + dir + '"]' : '');
    const el = $(q, els.fuse); if (el && !el.disabled) el.focus(); else { const any = $('[data-part="' + id + '"]', els.fuse); if (any) any.focus(); }
  }

  // ---------- taps ----------
  function onTap(e) {
    const pb = e.target.closest('[data-plate]');
    if (pb) { runPlateAct(els.plate._acts[+pb.dataset.plate]); return; }
    const act = e.target.closest('[data-act]');
    if (act) { doAct(act); return; }
    const rip = e.target.closest('.ripple');
    if (rip) {
      const sign = $('[data-target="' + cssq(rip.dataset.ref) + '"]');
      const vis = sign && sign.offsetParent !== null && !sign.closest('[data-covered]');
      if (vis && innerWidth < 600) sign.scrollIntoView({ block: 'center', behavior: reduced ? 'auto' : 'smooth' });
      openPlate(rip.dataset.ref, vis ? sign : rip);
      return;
    }
    const sign = e.target.closest('[data-target]');
    if (sign) {
      if (sign.classList.contains('plaque') && !reduced) { sign.classList.remove('swing'); void sign.offsetWidth; sign.classList.add('swing'); }
      if (ui.selected && ui.selected.ref === sign.dataset.target) { closePlate(); return; }
      openPlate(sign.dataset.target, sign);
      return;
    }
    if (!e.target.closest('#plate')) closePlate();
  }
  function doAct(el) {
    const a = el.dataset.act;
    if (a === 'plate-close') return closePlate();
    if (a === 'open-app') return sdk.open(el.dataset.app);
    if (a === 'ask') return sdk.ask(el.dataset.widget);
    if (a === 'settings') return sdk.settings(el.dataset.page);
    if (a === 'feed-press') { sdk.press(el.dataset.binding, el.dataset.action); if (el.dataset.feed) { ui.working[el.dataset.feed] = true; schedule(); } return; }
    if (a === 'fusebox') { ui.fuse = !ui.fuse; ui.note = null; els.fuse.hidden = !ui.fuse; if (ui.fuse) { els.fuse.innerHTML = N.renderFusebox(state, ui); closePlate(); const f = $('.switch', els.fuse); if (f) f.focus(); } render(); return; }
    if (a === 'part-toggle') return togglePart(el.dataset.part);
    if (a === 'part-move') return movePart(el.dataset.part, +el.dataset.dir);
  }

  // ---------- start ----------
  function boot() {
    els.root = $('#street'); els.header = $('#header'); els.wall = $('#wall'); els.level = $('#level');
    els.puddle = $('#puddle-index'); els.plate = $('#plate'); els.fuse = $('#fusebox');
    document.documentElement.classList.add('js');
    if (!sdk || typeof sdk.stream !== 'function') { els.puddle.innerHTML = '<p class="calm">Open this desktop in CYFR to light the street.</p>'; return; }
    takeDesktop(sdk.desktop);
    sdk.on('desktop', (d) => { takeDesktop(d); schedule(); });
    sdk.on('installed', (list) => changed(() => takeInstalled(list)));
    sdk.on('covered', (list) => setCovered(list));
    sdk.on('posture', (p) => { els.root.dataset.posture = p === 'hand' ? 'hand' : 'desk'; schedule(); });
    sdk.on('state', setLive);
    render();
    for (const key of N.OPEN) follow(key);
    if (!reduced) { els.root.classList.add('striking'); setTimeout(() => els.root.classList.remove('striking'), 1800); }
    document.addEventListener('click', onTap);
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape') return;
      if (!els.plate.hidden) { const back = ui.selected && $('[data-target="' + cssq(ui.selected.ref) + '"]'); closePlate(); if (back) back.focus(); }
      else if (ui.fuse) doAct({ dataset: { act: 'fusebox' } });
    });
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(schedule);
    addEventListener('resize', () => { schedule(); if (!els.plate.hidden && ui.selected) { const a = $('[data-target="' + cssq(ui.selected.ref) + '"]'); if (a) placePlate(a); } });
    if (window.Scene) Scene.init(els.root, () => state);
    els.wall.addEventListener('scroll', () => { if (window.Scene) Scene.relayout(); placeRipples(); }, { passive: true });
    // Times on the street move on.
    setInterval(() => { if (ui.live) schedule(); }, 30000);
    // Ready once every stream's first open has its answer, or after a few
    // seconds, so a stream that takes its time never fails the desktop.
    const firsts = [...followers.values()].map((f) => f.first);
    Promise.race([Promise.allSettled(firsts), new Promise((r) => setTimeout(r, 5000))]).then(() => sdk.ready());
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();

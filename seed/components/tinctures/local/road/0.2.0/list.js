// The plain page: the same data as the village, as lists, for a browser where the scene cannot
// draw. It reads Road.state as the scene does, and offers the same few taps.
window.RoadList = (function () {
  const R = Road, S = Road.state;
  const root = document.getElementById('lists');
  let shown = false, queued = false, said = '';

  function at(m) {
    if (m == null) return '';
    const a = S.appearance || {};
    try { return new Date(R.utcOf(m)).toLocaleString(a.locale || undefined, { timeZone: a.time_zone || undefined, weekday: 'short', hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return new Date(R.utcOf(m)).toLocaleString(); }
  }
  function el(tag, text, cls) { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
  function button(text, run) { const b = el('button', text); b.type = 'button'; b.addEventListener('click', run); return b; }
  // A section titled with what its part says while it is not live.
  function section(title, part, items, empty) {
    const s = el('section'), note = R.note(part);
    s.appendChild(el('h2', title + (note ? ' (' + note.text + ')' : '')));
    if (!items.length) { s.appendChild(el('p', empty)); return s; }
    const ul = el('ul');
    for (const [text, bad, ...buttons] of items) { const li = el('li', text, bad ? 'bad' : null); for (const b of buttons) li.append(' ', b); ul.appendChild(li); }
    s.appendChild(ul);
    return s;
  }
  function retry(id) {
    return button('Retry run', async () => { said = await R.retry(id); render(); });
  }

  const KIND = { failed_run: 'failed', failed_schedule: 'failed', approval: 'waits for your approval', confirmation: 'waits for your confirmation', file_offer: 'is offered to you', grant: 'waits for your grant' };
  const cause = (c) => (c ? ' (' + c.replace(/_/g, ' ') + ')' : '');
  const size = (b) => (b == null ? 'not known' : Math.round(b / 1e9) + ' GB');
  function render() {
    if (!shown) return;
    document.documentElement.dataset.mode = S.appearance && S.appearance.mode === 'dark' ? 'dark' : 'light';
    const v = (m) => R.values(m);
    const sys = v(S.system)[0];
    const sched = (id) => ((S.schedules.get(id) || {}).value || { name: 'A schedule' }).name;
    const runs = v(S.runs).filter((r) => !r.parent).sort((a, b) => (b.started ?? 0) - (a.started ?? 0));
    root.replaceChildren(
      el('p', said, null),
      section('Waiting on you', 'attention', R.waiting().map((a) => [(a.kind === 'file_offer' && a.from ? a.from + ' offers ' + a.label : a.label + ' ' + (KIND[a.kind] || 'waits')) + (a.since != null ? ', since ' + at(a.since) : ''), a.kind.startsWith('failed'),
        ...(a.kind === 'failed_run' && R.retryable(a.ref) ? [retry(a.ref)] : []), ...(a.page ? [button('Open', () => R.settings(a.page))] : []), ...(a.kind === 'grant' ? [button('Review grant', () => R.grant(a.ref))] : [])]), 'Nothing waits on you.'),
      section('Schedules', 'schedules', v(S.schedules).map((s) => [s.name + ': ' + (s.status === 'active' ? 'next ' + at(s.next) : s.status) + ', ' + s.runs + (s.runs === 1 ? ' run, ' : ' runs, ') + s.errors + (s.errors === 1 ? ' error' : ' errors'), s.errors > 0,
        ...(s.status === 'active' || s.status === 'paused' ? [button(s.status === 'active' ? 'Pause' : 'Resume', () => R.press(s.status === 'active' ? R.PAUSE : R.RESUME, s.id))] : [])]), 'No schedules.'),
      section('Schedule runs', 'schedules', v(S.scheduleRuns).sort((a, b) => (b.at ?? 0) - (a.at ?? 0)).slice(0, 10).map((r) => [sched(r.sid) + ' ' + (r.kind === 'failed' ? 'failed' : 'ran') + ' at ' + at(r.at) + cause(r.cause), r.kind === 'failed',
        ...(r.kind === 'failed' && R.retryable(r.eid) ? [retry(r.eid)] : [])]), 'Nothing has fired lately.'),
      section('Runs', 'schedules', runs.slice(0, 10).map((r) => [r.name + ' ' + ({ failed: 'failed', completed: 'ran', started: 'is running' }[r.kind] || 'was cancelled') + ', started ' + at(r.started) + (r.ended != null ? ', ended ' + at(r.ended) : '') + cause(r.cause), r.kind === 'failed',
        ...(R.retryable(r.id) ? [retry(r.id)] : [])]), 'No runs lately.'),
      section('Threads', 'threads', v(S.threads).map((t) => [t.title + (t.waits ? ', waits on you' : '') + (t.unread ? ', ' + t.unread + ' unread' : '') + ', ' + at(t.last), t.waits]), 'No threads.'),
      section('Crew at work', 'activity', v(S.activity).map((j) => [j.member + (j.title ? ': ' + j.title : '') + ' since ' + at(j.since) + (j.status ? ' (' + j.status + ')' : ''), false]), 'Nobody is at work.'),
      section('Apps', 'components', S.installed.map((a) => [a.name + (a.open ? ' (open)' : '') + ((R.component(a.ref) || {}).update ? ', update ready' : ''), false, button('Open', () => R.open(a.ref))]), 'No apps installed.'),
      section('Vault', 'vault', v(S.vault).map((e) => [e.name + ': ' + (e.fine ? 'fine' : 'needs re-authorisation'), !e.fine]), 'No vault entries.'),
      section('Files', 'files', v(S.files).map((f) => [f.name + (f.kind === 'offer' ? ', offered by ' + (f.from || 'someone') : ', changed ' + at(f.changed)), false]), 'No recent files and no offers.'),
      section('CYFR', 'system', sys ? [[{ ok: 'All is well', degraded: 'Something is not working as it should', low_storage: 'Storage is running low' }[sys.health] || 'Health not known', sys.health !== 'ok'],
        ['Storage: ' + size(sys.used) + (sys.cap ? ' of ' + size(sys.cap) : ''), false], [sys.model ? 'A model is connected' : 'No model is connected', false],
        ['Crew: ' + (sys.ready ?? 0) + ' of ' + (sys.total ?? 0) + ' ready', false], ['Version ' + (sys.version || 'not known') + (sys.update ? ', an update is ready' : ''), false]] : [], 'Not read yet.'),
      ...['weather', 'vpn'].map((name) => { const f = S.feeds[name]; return section(name === 'vpn' ? 'VPN' : 'Weather', name, f ? [[f.label + ', updated ' + at(f.at), false, ...f.actions.map((a) => button(a.label, () => R.pressFeed(name, a.name)))]] : [], 'No ' + name + ' feed is bound.'); }),
    );
  }
  R.subscribe(() => {
    if (shown && !queued) { queued = true; setTimeout(() => { queued = false; render(); }, 250); }
  });
  return { show() { shown = true; document.documentElement.classList.remove('scene'); render(); } };
})();

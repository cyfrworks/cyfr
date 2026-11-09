// The plain page: the same data as the village, as lists, for a browser where the scene cannot
// draw. It reads Road.state as the scene does, and offers the same few taps.
window.RoadList = (function () {
  const R = Road, S = Road.state;
  const root = document.getElementById('lists');
  let shown = false, queued = false;

  function at(m) {
    if (m == null) return '';
    const a = S.appearance || {};
    try { return new Date(R.utcOf(m)).toLocaleString(a.locale || undefined, { timeZone: a.time_zone || undefined, weekday: 'short', hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return new Date(R.utcOf(m)).toLocaleString(); }
  }
  function el(tag, text, cls) { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
  function button(text, run) { const b = el('button', text); b.type = 'button'; b.addEventListener('click', run); return b; }
  function section(title, items, empty) {
    const s = el('section');
    s.appendChild(el('h2', title));
    if (!items.length) { s.appendChild(el('p', empty)); return s; }
    const ul = el('ul');
    for (const [text, bad, ...buttons] of items) { const li = el('li', text, bad ? 'bad' : null); for (const b of buttons) li.append(' ', b); ul.appendChild(li); }
    s.appendChild(ul);
    return s;
  }

  const KIND = { failed_run: 'failed', failed_schedule: 'failed', approval: 'waits for your approval', confirmation: 'waits for your confirmation', file_offer: 'is offered to you' };
  function render() {
    if (!shown) return;
    document.documentElement.dataset.mode = S.appearance && S.appearance.mode === 'dark' ? 'dark' : 'light';
    const v = (m) => R.values(m);
    const w = S.feeds.weather, vpn = S.feeds.vpn;
    root.replaceChildren(
      section('Waiting on you', v(S.attention).map((a) => [a.label + ' ' + (KIND[a.kind] || 'waits') + ', since ' + at(a.since), a.kind.startsWith('failed'), ...(a.page ? [button('Open', () => R.settings(a.page))] : [])]), 'Nothing waits on you.'),
      section('Schedules', v(S.schedules).map((s) => [s.name + ': ' + (s.status === 'active' ? 'next ' + at(s.next) : s.status) + ', ' + s.runs + (s.runs === 1 ? ' run, ' : ' runs, ') + s.errors + (s.errors === 1 ? ' error' : ' errors'), s.errors > 0,
        ...(s.status === 'active' || s.status === 'paused' ? [button(s.status === 'active' ? 'Pause' : 'Resume', () => R.press(s.status === 'active' ? R.PAUSE : R.RESUME, s.id))] : [])]), 'No schedules.'),
      section('Schedule runs', v(S.scheduleRuns).sort((a, b) => (b.at ?? 0) - (a.at ?? 0)).slice(0, 10).map((r) => [((S.schedules.get(r.sid) || {}).value || { name: 'A schedule' }).name + ' ' + (r.kind === 'failed' ? 'failed' : 'ran') + ' at ' + at(r.at) + (r.cause ? ' (' + r.cause.replace(/_/g, ' ') + ')' : ''), r.kind === 'failed']), 'Nothing has fired lately.'),
      section('Threads', v(S.threads).map((t) => [t.title + (t.waits ? ', waits on you' : '') + ', ' + at(t.last), t.waits]), 'No threads.'),
      section('Crew at work', v(S.activity).map((j) => [j.member + ' since ' + at(j.since) + (j.status ? ' (' + j.status + ')' : ''), false]), 'Nobody is at work.'),
      section('Apps', S.installed.map((a) => [a.name + (a.open ? ' (open)' : ''), false, button('Open', () => R.open(a.ref))]), 'No apps installed.'),
      section('Vault', v(S.vault).map((e) => [e.name + ': ' + (e.fine ? 'fine' : 'needs re-authorisation'), !e.fine]), 'No vault entries.'),
      section('Feeds', [w, vpn].filter(Boolean).map((f) => [f.label + ', updated ' + at(f.at), false, ...f.actions.map((a) => button(a.label, () => R.pressFeed(f === w ? 'weather' : 'vpn', a.name)))]), 'No weather or vpn feed is bound.'),
    );
  }
  R.subscribe(() => {
    if (shown && !queued) { queued = true; setTimeout(() => { queued = false; render(); }, 250); }
  });
  return { show() { shown = true; document.documentElement.classList.remove('scene'); render(); } };
})();

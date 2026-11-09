/* The plain listing: what the streams say, as lists, shown in place of the
   board when the board cannot be drawn. It reads the same state and uses
   nothing but text. */
(function () {
  'use strict';

  const { state, text, isItem, componentName } = window.SB;
  const KIND = { approval: 'approval', confirmation: 'confirmation', failed_run: 'failed run', failed_schedule: 'failed schedule', file_offer: 'file offer' };

  function when(iso) {
    const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
    if (Number.isNaN(t)) return '';
    try {
      return new Intl.DateTimeFormat(state.appearance.locale, { timeZone: state.appearance.time_zone, weekday: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(t));
    } catch (_) { return new Date(t).toLocaleString(); }
  }
  function section(title, rows, empty) {
    const s = document.createElement('section');
    const h = document.createElement('h2'); h.textContent = title; s.appendChild(h);
    if (!rows.length) { const p = document.createElement('p'); p.textContent = empty; s.appendChild(p); return s; }
    const ul = document.createElement('ul');
    for (const row of rows) { const li = document.createElement('li'); li.textContent = row.filter(Boolean).join(' · '); ul.appendChild(li); }
    s.appendChild(ul);
    return s;
  }

  function render(el) {
    const items = (map) => [...map.values()].map((h) => h.item);
    const out = [];
    const h1 = document.createElement('h1'); h1.textContent = state.person ? `CYFR · ${state.person}` : 'CYFR'; out.push(h1);
    const lead = document.createElement('p'); lead.className = 'plain-lead';
    lead.textContent = `${state.attention.size} ${state.attention.size === 1 ? 'thing waits' : 'things wait'} on you.`;
    out.push(lead);
    out.push(section('Waiting on you', items(state.attention).map((a) => [text(a.label), KIND[a.kind] || text(a.kind), when(a.since)]), 'Nothing waits on you.'));
    out.push(section('Threads', items(state.threads).map((t) => [text(t.title), t.kind === 'own' ? 'own' : 'shared', t.waits_on_you ? 'waits on you' : '', when(t.last_activity)]), 'No threads yet.'));
    out.push(section('Apps', state.installed.map((a) => [a.name, a.open ? 'open' : '']), 'No apps installed.'));
    out.push(section('Components', [...window.SB.components().values()].filter((c) => c.type !== 'tincture' && c.type !== 'agent').map((c) => [text(c.name), text(c.type), text(c.version), c.update_available ? 'update ready' : '']), 'No components installed.'));
    out.push(section('Schedules', items(state.schedules).map((s) => [text(s.name) || componentName(s.reference), text(s.cron_expression), text(s.status), s.status === 'active' ? `next ${when(s.next_run_at)}` : '', `${text(s.run_count) || 0} runs`, `${text(s.error_count) || 0} errors`]), 'Nothing is scheduled.'));
    out.push(section('Runs', state.runs.map((r) => [componentName(r.reference), text(r.kind), isItem(r.error) ? text(r.error.cause).replace(/_/g, ' ') : '']), 'No runs yet.'));
    const f = state.feeds.weather;
    out.push(section(f ? text(f.label) || 'Weather' : 'Weather', f && isItem(f.result) ? Object.entries(f.result).filter(([, v]) => typeof v !== 'object').map(([k, v]) => [k.replace(/_/g, ' '), String(v)]) : [], 'No weather feed is bound.'));
    out.push(section('Vault', items(state.vault).map((v) => [text(v.name), v.status === 'fine' ? 'fine' : 'needs re-authorisation']), 'Nothing stored.'));
    out.push(section('Crew', items(state.activity).map((j) => [text(j.member), `for ${text(j.asked_by)}`, when(j.since), text(j.status)]), 'No crew job running.'));
    el.replaceChildren(...out);
  }

  window.Plain = { render };
})();

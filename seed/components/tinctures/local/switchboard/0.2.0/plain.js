/* The plain listing: what the streams say, as lists, shown in place of the
   board when the board cannot be drawn. It reads the same state and uses
   nothing but text. */
(function () {
  'use strict';

  const SB = window.SB;
  const { state, text, isItem, componentName } = SB;
  const KIND = { approval: 'approval', confirmation: 'confirmation', failed_run: 'failed run', failed_schedule: 'failed schedule', file_offer: 'file offer' };
  const HEALTH = { ok: 'healthy', degraded: 'degraded', low_storage: 'low storage' };

  function when(iso) {
    const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
    if (Number.isNaN(t)) return '';
    try {
      return new Intl.DateTimeFormat(state.appearance.locale, { timeZone: state.appearance.time_zone, weekday: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(t));
    } catch (_) { return new Date(t).toLocaleString(); }
  }
  const gb = (bytes) => (Number.isFinite(bytes) ? `${Math.round(bytes / 1e9)} GB` : '');
  function section(title, rows, empty) {
    const s = document.createElement('section');
    const h = document.createElement('h2'); h.textContent = title; s.appendChild(h);
    if (!rows.length) { const p = document.createElement('p'); p.textContent = empty; s.appendChild(p); return s; }
    const ul = document.createElement('ul');
    for (const row of rows) { const li = document.createElement('li'); li.textContent = row.filter(Boolean).join(' · '); ul.appendChild(li); }
    s.appendChild(ul);
    return s;
  }
  function feed(name) {
    const f = SB.feed(name);
    const rows = f && isItem(f.result) ? Object.entries(f.result).map(([k, v]) => [k.replace(/_/g, ' '), Array.isArray(v) ? v.join(', ') : typeof v === 'object' ? '' : String(v)]) : [];
    return section(f ? text(f.label) || name : name, rows, `No feed named ${name} is bound.`);
  }

  function render(el) {
    const out = [];
    const calls = SB.attention();
    const h1 = document.createElement('h1'); h1.textContent = state.person ? `CYFR · ${state.person}` : 'CYFR'; out.push(h1);
    const lead = document.createElement('p'); lead.className = 'plain-lead';
    lead.textContent = `${calls.length} ${calls.length === 1 ? 'thing waits' : 'things wait'} on you.`;
    out.push(lead);
    out.push(section('Waiting on you', calls.map((a) => [text(a.label), KIND[a.kind] || text(a.kind), when(a.since)]), 'Nothing waits on you.'));
    out.push(section('Threads', SB.threads().map((t) => [text(t.title), t.kind === 'own' ? 'own' : 'shared', t.waits_on_you ? 'waits on you' : '', Number.isInteger(t.unread) && t.unread > 0 ? `${t.unread} unread` : '', when(t.last_activity)]), 'No threads yet.'));
    out.push(section('Apps', state.installed.map((a) => [a.name, a.open ? 'open' : '']), 'No apps installed.'));
    out.push(section('Components', [...SB.components().values()].filter((c) => c.type !== 'tincture' && c.type !== 'agent').map((c) => [text(c.name), text(c.type), text(c.version), c.update_available ? 'update ready' : '']), 'No components installed.'));
    out.push(section('Schedules', SB.schedules().map((s) => [text(s.name) || componentName(s.reference), text(s.cron_expression), text(s.status), s.status === 'active' ? `next ${when(s.next_run_at)}` : '', `${text(s.run_count) || 0} runs`, `${text(s.error_count) || 0} errors`]), 'Nothing is scheduled.'));
    out.push(section('Runs', SB.runs().map((r) => [when(r.started_at), componentName(r.reference), text(r.kind), isItem(r.error) ? text(r.error.cause).replace(/_/g, ' ') : '']), 'No runs yet.'));
    out.push(feed('weather'));
    out.push(feed('vpn'));
    out.push(section('Vault', SB.vault().map((v) => [text(v.name), v.status === 'fine' ? 'fine' : 'needs re-authorisation']), 'Nothing stored.'));
    const s = SB.system();
    out.push(section('System', s ? [[HEALTH[s.health] || '', gb(s.storage_used) && `${gb(s.storage_used)} of ${gb(s.storage_cap)} used`, s.model_connected === true ? 'model connected' : s.model_connected === false ? 'model not connected' : '', Number.isInteger(s.crew_ready) ? `${s.crew_ready} of ${text(s.crew_total)} crew ready` : '', `CYFR ${text(s.version)}`, s.update_available ? 'update available' : '']] : [], 'Not read yet.'));
    out.push(section('Crew', SB.activity().map((j) => [text(j.member), `for ${text(j.asked_by)}`, when(j.since), text(j.title) || text(j.status)]), 'No crew job running.'));
    out.push(section('Files', SB.files().map((f) => (f.kind === 'offer' ? [text(f.name), text(f.from) ? `offered by ${f.from}` : 'offered'] : [text(f.name), when(f.changed_at)])), 'No recent files.'));
    el.replaceChildren(...out);
  }

  window.Plain = { render };
})();

// The decision line: what waits on the person's tap on the near side, what
// their CYFR runs on its own on the far side; a settled item crosses the
// line into today's log.
//
// Everything the page shows comes from the streams its manifest declares,
// the current state first and then changes, and from what the shell tells
// it (installed apps, posture, covered rects, live or frozen, the desktop's
// preferences, appearance and the person's name). It acts only through the
// shell's verbs, each on a tap: a control press (pause, resume, retry), a
// preferences write (arrange), a feed's action, open, ask and settings.
"use strict";

(() => {
  const sdk = window.cyfr;
  const doc = document.documentElement;
  const $ = (s, r = document) => r.querySelector(s);

  // ---------------------------------------------------------------- model

  // The widgets, each a widget of the preferences document; the queue is
  // pinned first on the near side and never turned off.
  const WIDGETS = {
    apps: { side: "near", title: "Apps" },
    threads: { side: "near", title: "Threads" },
    weather: { side: "far", title: "Weather", size: "s", feed: "weather" },
    vpn: { side: "far", title: "VPN", size: "s", feed: "vpn" },
    system: { side: "far", title: "System", size: "s" },
    schedules: { side: "far", title: "Schedules" },
    today: { side: "far", title: "Today" },
    vault: { side: "far", title: "Vault" },
    day: { side: "far", title: "The day", size: "wide" },
  };
  const DEFAULT_ORDER = Object.keys(WIDGETS);
  // Which widgets are on at each screen size until the person says
  // otherwise: the carried screen fits everything it shows in 600 pixels.
  const DEFAULT_ON = {
    phone: ["apps", "threads", "weather", "vpn", "system", "schedules", "today"],
    carried: ["apps", "weather", "vpn", "schedules", "today"],
    desk: ["apps", "threads", "weather", "vpn", "system", "schedules", "today", "vault", "day"],
  };
  // The streams each part reads; a part shows the worst state among them.
  const READS = {
    queue: ["attention.changes"],
    apps: ["components.changes"],
    threads: ["threads.changes"],
    weather: ["feed.results:weather"],
    vpn: ["feed.results:vpn"],
    system: ["system.changes"],
    schedules: ["schedules.changes"],
    today: ["runs.changes", "activity.changes", "schedule_runs.changes"],
    vault: ["vault.changes"],
    day: ["attention.changes", "runs.changes", "activity.changes", "schedules.changes"],
  };
  // How many rows a list shows before "all", per size.
  const CAP = { phone: 6, carried: 4, desk: 6 };
  const PAUSE = "pause-schedule";
  const RESUME = "resume-schedule";
  const RETRY = "retry-run";
  const MAX_RUNS = 20;
  const RETRY_MS = [2000, 5000, 15000, 60000];
  // How long the first draw waits for the opens before the page tells the
  // shell it is ready, well inside the ten seconds the shell gives it.
  const READY_MS = 6000;
  const NOTE_MS = 4000;
  const SAID_MS = 8000;
  // The refusal classes a grant can fix, and the cause a run's error reads
  // as for them, as the shipped canvas reads them.
  const GRANTABLE = ["consent_required", "setup_required"];
  const GRANT_CAUSES = ["needs_setup"];
  const CAUSES = {
    needs_setup: "needs setup", unavailable: "unavailable", timed_out: "timed out",
    cancelled: "cancelled", rate_limited: "rate limited", refused: "refused",
    bad_input: "bad input", not_found: "not found", waits_for_you: "waits for you",
  };
  // What a press of Retry answered, in this desktop's words.
  const BUSY_NOW = "CYFR can't run it now. Try again shortly";
  const RETRY_SAID = {
    conflict: "Only a run a schedule or a feed started runs again",
    invalid_argument: "No longer among the latest runs",
    not_found: "This run is gone",
    forbidden: "Not yours to run again",
    unavailable: BUSY_NOW, rate_limited: BUSY_NOW, timeout: BUSY_NOW,
    uncertain: "No answer came. Look at Runs before trying again",
  };
  const HEALTH = {
    ok: { words: "Healthy", dot: "pos" },
    degraded: { words: "Needs a look", dot: "neg" },
    low_storage: { words: "Storage is low", dot: "neg" },
  };

  const S = {
    installed: [],
    covered: [],
    live: true,
    prefs: {},
    appearance: {},
    person: null,
    settled: [], // seen leaving the attention stream, this session only
    arranging: false,
    saved: null,
    note: null,
    busy: {}, // a pressed schedule, run or feed, until its answer
    notes: {}, // a press's answer, by row: {words, ok}
  };

  // ----------------------------------------------------------- the clock

  function zone() {
    const tz = S.appearance && typeof S.appearance.time_zone === "string" ? S.appearance.time_zone : undefined;
    const locale = S.appearance && typeof S.appearance.locale === "string" ? S.appearance.locale : undefined;
    try {
      new Intl.DateTimeFormat(locale, { timeZone: tz });
      return { tz, locale };
    } catch (_e) {
      return { tz: undefined, locale: undefined };
    }
  }
  function parts(d) {
    const { tz } = zone();
    const p = {};
    for (const { type, value } of new Intl.DateTimeFormat("en-GB", {
      timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    }).formatToParts(d)) p[type] = value;
    return { day: `${p.year}-${p.month}-${p.day}`, minutes: Number(p.hour) * 60 + Number(p.minute) };
  }
  function hm(d) {
    const { tz, locale } = zone();
    return new Intl.DateTimeFormat(locale, { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(d);
  }
  function weekday(d) {
    const { tz, locale } = zone();
    return new Intl.DateTimeFormat(locale, { timeZone: tz, weekday: "short" }).format(d);
  }
  const date = (v) => {
    if (v instanceof Date) return v;
    const t = typeof v === "string" ? Date.parse(v) : NaN;
    return Number.isNaN(t) ? null : new Date(t);
  };
  // A time as the queue and the logs say it: "09:00" today, "Yesterday",
  // "Mon 09:00" within the week, else the date.
  function when(v) {
    const d = date(v);
    if (!d) return "";
    const now = new Date();
    const a = parts(d).day, b = parts(now).day;
    if (a === b) return hm(d);
    const days = Math.round((Date.parse(b) - Date.parse(a)) / 86400000);
    if (days === 1) return "Yesterday";
    if (days > 1 && days < 7) return `${weekday(d)} ${hm(d)}`;
    if (days < 0 && days > -7) return `${weekday(d)} ${hm(d)}`;
    const { tz, locale } = zone();
    return new Intl.DateTimeFormat(locale, { timeZone: tz, day: "numeric", month: "short" }).format(d);
  }

  // ------------------------------------------------------------- reading

  const isItem = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
  const text = (v) => (typeof v === "string" ? v : typeof v === "number" && Number.isFinite(v) ? String(v) : "");
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const ic = (id, cls = "") => `<svg class="i ${cls}" aria-hidden="true"><use href="#i-${id}"/></svg>`;
  const plural = (k, one, many) => (k === 1 ? one : many);
  const capital = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  const nf = () => new Intl.NumberFormat(zone().locale);
  const duration = (ms) => (typeof ms === "number" && Number.isFinite(ms) ? (ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`) : "");
  const ISO_TIME = /^\d{4}-\d\d-\d\dT\d\d:\d\d/;
  const human = (key) => capital(String(key).replace(/[_-]+/g, " "));
  const count = (v) => (Number.isInteger(v) && v >= 0 ? v : null);

  // "formula:local.digest:1.0.0" without its version.
  function componentRef(reference) {
    const p = String(reference).split(":");
    return p.length === 3 ? `${p[0]}:${p[1]}` : String(reference);
  }
  // "catalyst:local.openai" as a person reads it: "openai".
  function componentName(reference) {
    const named = componentRef(reference).split(":")[1] || "";
    return named.includes(".") ? named.slice(named.indexOf(".") + 1) : named || String(reference);
  }
  // A reference reads as the schedule that runs it, when one does.
  function refName(reference) {
    const ref = componentRef(reference);
    for (const item of items("schedules.changes")) {
      if (componentRef(text(item.reference)) === ref && text(item.name)) return text(item.name);
    }
    return componentName(reference);
  }
  // The schedule occurrence that started a run, when a schedule did.
  const firedBy = (run) => items("schedule_runs.changes").find((o) => text(o.execution_id) === text(run.execution_id)) || null;
  function runName(run) {
    const fired = firedBy(run);
    const schedule = fired && held("schedules.changes").get(text(fired.schedule_id));
    return schedule && text(schedule.name) ? text(schedule.name) : refName(text(run.reference));
  }
  const grantable = (error) => isItem(error) && (GRANTABLE.includes(error.class) || GRANT_CAUSES.includes(error.cause));
  const runs = () => items("runs.changes").sort((a, b) => (date(b.started_at) || 0) - (date(a.started_at) || 0));
  const runOf = (id) => (id ? held("runs.changes").get(id) || null : null);
  const lastFailure = (reference) => runs().find((r) => r.kind === "failed" && text(r.reference) === reference) || null;
  const cause = (error) => (isItem(error) ? CAUSES[error.cause] || text(error.class) : "");

  // ---------------------------------------------------- holding streams

  // Every stream the manifest declares, opened once at start and kept open;
  // each holds its items by its key under the delivery contract
  // (`canvas.catalog`): per item the highest revision heard, a picture
  // gathered apart until its `snapshot` replaces what was held, and a
  // removal that keeps its revision so an older change cannot bring the
  // item back. `cap` keeps the newest by a time field; a change with no key
  // is a notice, shown and never held; a `reread` kind heard live only
  // announces the fresh picture that follows.
  const fresh = () => ({ items: new Map(), revs: new Map() });
  const STREAMS = [
    { name: "attention.changes", key: "id", removal: "removed" },
    { name: "runs.changes", key: "execution_id", cap: [MAX_RUNS, "started_at"] },
    { name: "schedules.changes", key: "schedule_id", removal: "removed" },
    { name: "schedule_runs.changes", key: "occurrence_id", cap: [MAX_RUNS, "scheduled_for"], notice: scheduleNotice },
    { name: "activity.changes", key: "id", removal: "ended" },
    { name: "threads.changes", key: "id", removal: "removed" },
    { name: "components.changes", key: "ref", removal: "removed", reread: ["installed", "pushed", "changed"] },
    { name: "vault.changes", key: "name", removal: "removed" },
    { name: "files.changes", key: "id", removal: "removed", reread: ["removed"] },
    { name: "system.changes", key: null },
    { name: "feed.results", subject: "weather", key: "binding" },
    { name: "feed.results", subject: "vpn", key: "binding" },
  ].map((s) => ({
    subject: null, ...s, ...fresh(),
    picture: null, state: "opening", at: null, retryAt: null,
    handle: null, opening: null, opens: 0, tries: 0, timer: null,
  }));
  const label = (stream) => (stream.subject ? `${stream.name}:${stream.subject}` : stream.name);
  const BY = Object.fromEntries(STREAMS.map((s) => [label(s), s]));
  const held = (name) => BY[name].items;
  const items = (name) => [...BY[name].items.values()];
  const one = (name) => items(name)[0] || null;
  // A feed's latest result: one binding in practice, the newest if more.
  const feed = (name) => items(`feed.results:${name}`).sort((a, b) => (date(b.at) || 0) - (date(a.at) || 0))[0] || null;

  function change(s, event) {
    const data = event.data;
    const id = s.key === null ? "status" : text(data[s.key]);
    if (!id) {
      if (s.notice && data.refresh !== true) s.notice(data);
      return;
    }
    if (s.reread && s.reread.includes(data.kind) && data.refresh !== true) return;
    const into = s.picture || s;
    const revision = Number.isInteger(event.revision) ? event.revision : Number.isInteger(data.revision) ? data.revision : null;
    const had = into.revs.get(id);
    if (revision !== null && had !== undefined && revision <= had) return;
    if (revision !== null) into.revs.set(id, revision);
    if (s.removal && data.kind === s.removal) {
      // Only a live removal from the queue crosses the line.
      if (s === BY["attention.changes"] && !s.picture && data.refresh !== true) return settle(id, data.outcome);
      return void into.items.delete(id);
    }
    into.items.set(id, data);
    if (s.cap) trim(into, s.cap);
    if (s.subject) delete S.busy[`feed:${s.subject}`];
  }

  function trim(into, [max, field]) {
    if (into.items.size <= max) return;
    const by = [...into.items].sort(([, a], [, b]) => (date(b[field]) || 0) - (date(a[field]) || 0));
    for (const [id] of by.slice(max)) {
      into.items.delete(id);
      into.revs.delete(id);
    }
  }

  // The delivery states, and each change, as the stream's handler hears them.
  function hear(s, event) {
    switch (event.event) {
      case "snapshot":
        if (s.picture) Object.assign(s, s.picture, { picture: null });
        Object.assign(s, { state: "live", at: null, retryAt: null });
        break;
      case "resync":
        s.picture = fresh();
        break;
      case "stale":
        Object.assign(s, { state: "stale", at: date(event.at) });
        break;
      case "unavailable":
        Object.assign(s, { state: "unavailable", retryAt: date(isItem(event.data) ? event.data.retry_at : null) });
        break;
      case "denied":
        Object.assign(s, fresh(), { picture: null, state: "denied" });
        break;
      default:
        if (event.event === s.name && isItem(event.data)) change(s, event);
    }
    changed();
  }

  // Opens one declared stream. The SDK opens an opened stream again by
  // itself after a lost connection; the page opens again only a first open
  // that got no answer, and a stream the endpoint ended with no refusal.
  function open(s) {
    if (s.opening) return s.opening;
    clearTimeout(s.timer);
    const n = ++s.opens;
    s.picture = fresh();
    s.opening = sdk.stream(s.name, s.subject, (event) => {
      if (n === s.opens && isItem(event)) hear(s, event);
    }).then((handle) => {
      Object.assign(s, { opening: null, handle, tries: 0 });
      const after = () => {
        if (s.handle === handle && handle.state === "ended") later(s);
      };
      handle.closed.then(after, after);
    }, (error) => {
      const code = error && error.code;
      s.opening = null;
      s.picture = null;
      if (code === "unavailable") Object.assign(s, { state: "unavailable", retryAt: new Date(Date.now() + later(s)) });
      else Object.assign(s, fresh(), { state: code === "forbidden" ? "refused" : "failed" });
      changed();
    });
    return s.opening;
  }
  function later(s) {
    const ms = RETRY_MS[Math.min(s.tries, RETRY_MS.length - 1)];
    s.tries += 1;
    clearTimeout(s.timer);
    s.timer = setTimeout(() => {
      if (!s.opening && !(s.handle && !["denied", "ended"].includes(s.handle.state))) open(s);
    }, ms);
    return ms;
  }
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // A part's state: the worst among the streams it reads, or null when
  // every one is live.
  const RANK = { stale: 1, unavailable: 2, failed: 3, refused: 4, denied: 5 };
  function worst(names) {
    let w = null;
    for (const name of names) {
      const s = BY[name];
      if (RANK[s.state] && (!w || RANK[s.state] > RANK[w.state])) w = s;
    }
    return w;
  }
  const ends = (s) => Boolean(s) && RANK[s.state] >= RANK.failed;
  function stateWords(s) {
    switch (s.state) {
      case "stale": return s.at ? `As of ${hm(s.at)}` : "Not fresh";
      case "unavailable": return s.retryAt ? `Can't be read now · trying again at ${hm(s.retryAt)}` : "Can't be read now";
      case "denied": return "No longer granted to this desktop";
      case "refused": return "Not granted to this desktop";
      default: return "This could not be read";
    }
  }
  // The part's body under its state: a stale picture dimmed, an ended part
  // its words alone, unless the part draws what no stream gives (`kept`
  // names what the stream adds, and the words say it is that).
  function under(st, body, kept = "") {
    if (!st) return body;
    const note = `<p class="state${ends(st) ? " off" : ""}">${esc(kept ? `${kept} · ${stateWords(st)}` : stateWords(st))}</p>`;
    if (ends(st) && !kept) return note;
    return note + (st.state === "stale" ? `<div class="tired">${body}</div>` : body);
  }

  // ------------------------------------------------- preferences, by size

  function size() {
    const w = innerWidth;
    return w >= 1200 ? "desk" : w >= 700 ? "carried" : "phone";
  }
  const widgetsDoc = () => (isItem(S.prefs) && isItem(S.prefs.widgets) ? S.prefs.widgets : {});
  const entry = (id) => (isItem(widgetsDoc()[id]) ? widgetsDoc()[id] : {});
  function isOn(id, at = size()) {
    const e = entry(id);
    if (e.on === false) return false;
    return typeof e[at] === "boolean" ? e[at] : DEFAULT_ON[at].includes(id);
  }
  function orderOf(id) {
    const e = entry(id);
    return Number.isInteger(e.order) ? e.order : DEFAULT_ORDER.indexOf(id);
  }
  function side(name) {
    return DEFAULT_ORDER.filter((id) => WIDGETS[id].side === name)
      .sort((a, b) => orderOf(a) - orderOf(b) || DEFAULT_ORDER.indexOf(a) - DEFAULT_ORDER.indexOf(b));
  }
  const shown = (name) => side(name).filter((id) => isOn(id));

  // One tap, one write: the widgets the document names replace their
  // entries whole, so each carries every field it keeps.
  function write(widgets) {
    if (!sdk) return;
    S.note = null;
    sdk.prefs({ widgets }).then((answer) => {
      const outcome = answer && answer.outcome;
      if (outcome === "saved") S.saved = new Date();
      else if (outcome === "stale") S.note = "Another of your screens saved first. Tap again to change this one.";
      else if (outcome === "refused") S.note = `Not saved: ${text(answer.reason) || "refused"}.`;
      else if (answer && answer.reason === "too_soon") S.note = "Not saved: too soon after your last tap. Tap again in a moment.";
      else S.note = "Not saved. Your desktop saves only on your tap.";
      changed();
    });
  }
  const full = (id, change) => ({ ...entry(id), on: true, ...change });
  function toggle(id) {
    write({ [id]: full(id, { [size()]: !isOn(id) }) });
  }
  // The side in the order given, renumbered; widgets that are off keep
  // their place after the ones that are on.
  function reorder(sideName, onList) {
    const rest = side(sideName).filter((id) => !onList.includes(id));
    const widgets = {};
    [...onList, ...rest].forEach((id, i) => {
      if (orderOf(id) !== i) widgets[id] = full(id, { order: i });
    });
    if (Object.keys(widgets).length) write(widgets);
  }
  function move(id, dir) {
    const list = shown(WIDGETS[id].side), i = list.indexOf(id), j = i + dir;
    if (i < 0 || j < 0 || j >= list.length) return;
    [list[i], list[j]] = [list[j], list[i]];
    reorder(WIDGETS[id].side, list);
  }

  // -------------------------------------------------------------- drawing

  const destination = (a) => (isItem(a.destination) ? a.destination : null);
  // The run a failed-run item names, while the runs picture holds it.
  const itemRun = (a) => {
    const dest = destination(a);
    return dest && dest.page === "executions" ? runOf(text(dest.ref)) : null;
  };
  const waitsOn = (executionId) => [...held("attention.changes").values()]
    .some((a) => a.kind === "failed_run" && itemRun(a) && text(itemRun(a).execution_id) === executionId);
  const KIND = {
    failed_run: { icon: "alert", neg: true, what: (a) => {
      const err = itemRun(a) || lastFailure(text(a.id));
      return ["Run failed", when(a.since), err && cause(err.error)].filter(Boolean).join(" · ");
    } },
    failed_schedule: { icon: "clock", neg: true, what: (a) => `Schedule failed · ${when(a.since)}` },
    approval: { icon: "approve", what: (a) => `Approval · since ${when(a.since)}` },
    confirmation: { icon: "key", what: (a) => `Confirmation · since ${when(a.since)}` },
    file_offer: { icon: "offer", what: (a) => {
      const from = offerFrom(a);
      return `File offer${from ? ` from ${from}` : ""} · since ${when(a.since)}`;
    } },
  };
  // Who offers a file, from the waiting offer of the same id, once
  // files.changes holds it; the row reads without it until then.
  function offerFrom(a) {
    const dest = destination(a), ids = [dest && text(dest.ref), text(a.id)].filter(Boolean);
    const offer = items("files.changes").find((f) => f.kind === "offer" && ids.includes(text(f.id)));
    return offer ? text(offer.from) : "";
  }
  const PAGE_ACT = { aqua: "Open in AQUA", chat: "Open chat", executions: "Open runs", schedules: "Open schedules", files: "Open files" };
  function about(a) {
    if (a.kind === "failed_run") return itemRun(a) ? runName(itemRun(a)) : refName(text(a.id));
    return text(a.label) || { approval: "An approval", confirmation: "A confirmation", file_offer: "A file", failed_schedule: "A schedule" }[a.kind] || "Something";
  }
  function settledWhat(kind, outcome) {
    if (outcome === "expired") return "Its time ran out";
    if (outcome === "withdrawn") return "Withdrawn before you got to it";
    return { approval: "Approval left your queue", failed_run: "A later run settled it", failed_schedule: "Its next run settled it",
      confirmation: "Decided in CYFR's prompt", file_offer: "File offer left your queue" }[kind] || "Left your queue";
  }
  // The one thing each item offers: a grant where one fixes a failed run,
  // Retry on a failed run the runs picture holds, the page it waits on
  // otherwise; a confirmation waits in CYFR's prompt.
  function action(a) {
    if (a.kind === "failed_run") {
      const run = itemRun(a) || lastFailure(text(a.id));
      if (run && grantable(run.error)) return { label: "Grant", act: "grant", ref: componentRef(text(a.id)), primary: true };
      if (itemRun(a)) return { label: "Retry", act: "retry", id: text(itemRun(a).execution_id), primary: true };
    }
    const dest = destination(a);
    if (dest && dest.kind === "page" && PAGE_ACT[dest.page]) return { label: PAGE_ACT[dest.page], act: "page", page: dest.page, ref: text(dest.ref), primary: false };
    return null;
  }
  const bySince = (a, b) => (date(a.since) || Infinity) - (date(b.since) || Infinity);
  const said = (key) => {
    const n = S.notes[key];
    return n ? `<span class="note${n.ok ? " ok" : ""}">${esc(n.words)}</span>` : "";
  };
  function retryButton(id, name, key, cls = "") {
    const busy = S.busy[`run:${id}`], words = busy ? "Retrying" : "Retry";
    return `<button class="btn${cls}" data-act="retry" data-id="${esc(id)}" data-key="${key}" aria-label="${esc(`${words}: ${name}`)}"${busy ? ' aria-disabled="true"' : ""}>${words}</button>`;
  }

  function queue() {
    const waiting = items("attention.changes").sort(bySince);
    const k = waiting.length;
    const st = worst(READS.queue);
    const name = S.person ? `${S.person}, y` : "Y";
    const title = ends(st) ? "What waits on you"
      : k ? `<span class="count">${k}</span> ${plural(k, "thing waits", "things wait")} on you` : "Nothing waits on you";
    const last = S.settled[0];
    const sub = k ? `Oldest since ${esc(when(waiting[0].since))}`
      : last ? `Last settled ${esc(hm(last.at))}: ${esc(last.label)}` : `${esc(name)}our CYFR carries on by itself`;
    const cap = size() === "phone" ? k : size() === "carried" ? 4 : 6;
    const rows = waiting.slice(0, cap).map((a) => {
      const K = KIND[a.kind] || KIND.approval, act = action(a);
      const button = !act ? `<span class="row-r">In CYFR's prompt</span>`
        : act.act === "retry" ? retryButton(act.id, about(a), `q-${esc(a.id)}`, " primary")
        : `<button class="btn${act.primary ? " primary" : ""}" data-act="${act.act}" data-page="${esc(act.page || "")}" data-ref="${esc(act.ref || "")}" data-key="q-${esc(a.id)}" aria-label="${esc(`${act.label}: ${about(a)}`)}">${esc(act.label)}</button>`;
      const note = act && act.act === "retry" ? said(`run:${act.id}`) : "";
      return `<li class="q-row" data-att="${esc(a.id)}"><span class="q-kind${K.neg ? " neg" : ""}">${ic(K.icon)}</span>
        <div style="min-width:0"><span class="q-about">${esc(about(a))}</span><span class="q-what${note ? " said" : ""}">${note || esc(K.what(a))}</span></div>${button}</li>`;
    }).join("");
    const body = k ? `<ol class="queue" aria-label="Oldest first">${rows}</ol>${k > cap ? `<p class="q-more">and ${k - cap} more, oldest first</p>` : ""}`
      : `<p class="q-empty">When a run fails, an approval waits or someone offers you a file, it waits here for your tap.</p>`;
    return `<div class="w w-queue"><div class="q-head"><div><h1 class="q-title">${title}</h1><p class="q-sub">${ends(st) ? "" : sub}</p></div>
      ${S.arranging ? "" : askBtn("queue", "what waits on you")}</div>${under(st, body)}</div>`;
  }

  const askBtn = (id, what) => `<button class="ib" data-act="ask" data-id="${id}" data-key="ask-${id}" aria-label="Ask AQUA about ${esc(what)}" title="Ask AQUA">${ic("drop")}</button>`;
  const pageLink = (page, words, key) => `<button class="link" data-act="page" data-page="${page}" data-key="${key}">${esc(words)}</button>`;

  const R = {
    apps() {
      const apps = S.installed;
      const updates = items("components.changes")
        .filter((c) => c.type === "tincture" && c.update_available === true)
        .map((c) => text(c.name)).filter(Boolean);
      const meta = updates.length
        ? pageLink("components", `${updates.join(", ")} ${plural(updates.length, "has an update", "have updates")}`, "updates")
        : apps.length ? `${apps.length} installed` : "";
      const body = apps.length === 0 ? `<p class="empty">No apps yet. Ask AQUA to make you one.</p>`
        : `<ul class="apps">${apps.map((a) => `<li><button class="app" data-act="open" data-ref="${esc(a.ref)}" data-key="app-${esc(a.ref)}" aria-label="Open ${esc(a.name)}${a.open ? " (open)" : ""}">
            <span class="app-ic">${esc(appMark(a))}</span><span class="app-name">${a.open ? '<span class="app-open" aria-hidden="true"></span>' : ""}${esc(a.name)}</span></button></li>`).join("")}</ul>`;
      // The apps come from the shell; only their updates from the stream.
      return { meta, body, kept: "Updates" };
    },
    threads() {
      const all = items("threads.changes")
        .sort((a, b) => (date(b.last_activity) || 0) - (date(a.last_activity) || 0));
      const list = all.slice(0, 4);
      return {
        meta: all.length ? `${list.length} of ${all.length}` : "",
        tools: `<button class="btn sm" data-act="page" data-page="chat" data-key="all-threads">All threads</button>`,
        body: list.length === 0 ? `<p class="empty">No threads yet.</p>` : `<ul class="rows">${list.map((t) => {
          const people = Array.isArray(t.people) ? t.people.length : 0;
          const shared = t.kind === "shared";
          const who = shared ? `${people} ${plural(people, "person", "people")}` : "With AQUA";
          const unread = count(t.unread);
          const flag = t.waits_on_you === true ? ` · <span class="mark">waits on you</span>`
            : unread ? ` · <b class="unread">${unread} unread</b>` : "";
          // A shared thread is in the chat; an own thread is AQUA's.
          return `<li class="row"><button class="row-btn" data-act="page" data-page="${shared ? "chat" : "aqua"}" data-ref="${esc(text(t.id))}" data-key="th-${esc(t.id)}">
            <span class="row-t">${esc(text(t.title) || "Untitled")}</span><span class="row-s">${who}${flag}</span></button>
            <span class="row-r num">${esc(when(t.last_activity))}</span></li>`;
        }).join("")}</ul>`,
      };
    },
    weather: () => feedCard("weather"),
    vpn: () => feedCard("vpn"),
    system() {
      const s = one("system.changes");
      if (!s) return { body: `<p class="empty">How your CYFR stands shows here once it is read.</p>` };
      const health = HEALTH[s.health];
      const used = count(s.storage_used), cap = count(s.storage_cap);
      const pct = used !== null && cap ? Math.min(100, Math.round((used / cap) * 100)) : null;
      const ready = count(s.crew_ready), total = count(s.crew_total);
      const kv = [
        typeof s.model_connected === "boolean" ? ["Model", s.model_connected ? "Connected" : "Not connected"] : null,
        ready !== null && total !== null ? ["Crew", `${ready} of ${total} ready`] : null,
      ].filter(Boolean);
      return {
        meta: text(s.version) ? `CYFR ${esc(s.version)}` : "",
        body: `<p class="sys-state">${health ? `<span class="dot ${health.dot}"></span>${health.words}` : ""}${s.update_available === true ? `<span class="upd">Update available</span>` : ""}</p>
          ${used !== null ? `<p class="sys-row"><span class="muted">Storage</span><span class="num">${esc(storage(used, cap))}</span></p>` : ""}
          ${pct !== null ? `<div class="bar" role="img" aria-label="${pct}% of storage used"><span style="width:${pct}%"></span></div>` : ""}
          ${kv.length ? `<dl class="kv">${kv.map(([k, v]) => `<dt>${k}</dt><dd class="num">${esc(v)}</dd>`).join("")}</dl>` : ""}`,
      };
    },
    schedules() {
      const at = (s) => (s.status === "paused" ? Infinity : (date(s.next_run_at) || Infinity));
      const list = items("schedules.changes").sort((a, b) => at(a) - at(b));
      const active = list.filter((s) => s.status === "active").length;
      const paused = list.filter((s) => s.status === "paused").length;
      const cap = CAP[size()];
      const n = nf();
      return {
        meta: list.length ? `${active} active · ${paused} paused` : "",
        body: list.length === 0 ? `<p class="empty">Nothing is scheduled. Ask AQUA to run something for you, say every morning at seven.</p>`
          : `<ul class="rows">${list.slice(0, cap).map((s) => {
            const id = text(s.schedule_id), busy = S.busy[`sch:${id}`], note = said(`sch:${id}`);
            const errors = Number(s.error_count) || 0;
            const sub = note
              || (s.status === "paused" ? `Paused · last ${esc(when(s.last_run_at) || "never")} · ${n.format(Number(s.run_count) || 0)} runs`
              : `Next ${esc(when(s.next_run_at) || "not planned")}${errors ? ` · <span class="neg-t">${errors} ${plural(errors, "error", "errors")}</span>` : ""} · ${n.format(Number(s.run_count) || 0)} runs`);
            const control = s.status === "active" ? PAUSE : s.status === "paused" ? RESUME : null;
            const words = control === PAUSE ? (busy ? "Pausing" : "Pause") : busy ? "Resuming" : "Resume";
            const button = control ? `<button class="btn sm" data-act="press" data-control="${control}" data-id="${esc(id)}" data-key="sc-${esc(id)}" aria-label="${esc(`${words} ${text(s.name)}`)}"${busy ? ' aria-disabled="true"' : ""}>${words}</button>` : "";
            return `<li class="row"><button class="row-btn" data-act="page" data-page="schedules" data-key="sr-${esc(id)}"><span class="row-t">${esc(text(s.name) || refName(text(s.reference)))}</span><span class="row-s">${sub}</span></button>${button}</li>`;
          }).join("")}</ul>${list.length > cap ? `<p class="more">${pageLink("schedules", `All ${list.length} schedules`, "all-sch")}</p>` : ""}`,
      };
    },
    today() {
      const cap = CAP[size()];
      const ran = runs();
      const rows = [
        ...ran.map((r, i) => ({ at: date(r.started_at), seq: -i, html: (t) => runRow(r, t) })),
        ...items("activity.changes").map((j) => ({ at: date(j.since), seq: 0, html: (t) => `<li class="row log"><span class="t">${t}</span>
          <div style="min-width:0"><span class="row-t">${esc(text(j.title) || text(j.member))}</span><span class="row-s">${text(j.title) ? esc(text(j.member)) : "Crew"}${j.asked_by ? ` · for ${esc(text(j.asked_by))}` : ""}</span></div>
          <span class="out"><span><span class="dot run"></span> ${esc(text(j.status) || "working")}</span></span></li>` })),
        ...S.settled.map((x) => ({ at: x.at, seq: Infinity, html: (t) => `<li class="row log" data-land="${esc(x.id)}"><span class="t">${t}</span>
          <div style="min-width:0"><span class="row-t">${esc(x.label)}</span><span class="row-s">${esc(x.what)}</span></div><span class="out">${esc(x.out)}</span></li>` })),
      ].sort((a, b) => (b.at ? b.at.getTime() : -1) - (a.at ? a.at.getTime() : -1) || b.seq - a.seq);
      const failed = ran.filter((r) => r.kind === "failed").length;
      return {
        meta: ran.length ? `${ran.length} ${plural(ran.length, "run", "runs")} · ${failed} failed` : "",
        body: rows.length === 0 ? `<p class="empty">No runs yet. A run shows here as it happens.</p>`
          : `<ul class="rows">${rows.slice(0, cap).map((r) => r.html(r.at ? esc(when(r.at)) : "")).join("")}</ul>${rows.length > cap ? `<p class="more">${pageLink("executions", `All runs`, "all-runs")}</p>` : ""}`,
      };
    },
    vault() {
      const list = items("vault.changes").sort((a, b) => text(a.name).localeCompare(text(b.name)));
      const need = list.filter((v) => v.status === "needs_reauthorisation").length;
      const cap = CAP[size()];
      return {
        meta: list.length ? `${list.length} ${plural(list.length, "entry", "entries")} · ${need} to look at` : "",
        body: list.length === 0 ? `<p class="empty">Your vault is empty.</p>`
          : `<ul class="rows">${list.slice(0, cap).map((v) => `<li class="row"><button class="row-btn" data-act="page" data-page="vault" data-key="v-${esc(v.name)}"><span class="row-t">${esc(text(v.name))}</span><span class="row-s">${esc(v.type ? human(v.type) : "Entry")}</span></button>${v.status === "needs_reauthorisation" ? `<span class="pill neg">Needs re-authorisation</span>` : `<span class="row-r">Fine</span>`}</li>`).join("")}</ul>`,
      };
    },
    day() {
      const now = new Date(), today = parts(now).day;
      const START = 360, END = 1440;
      const x = (d) => {
        const p = parts(d);
        const m = p.day < today ? START : p.day > today ? END : Math.min(END, Math.max(START, p.minutes));
        return ((m - START) / (END - START)) * 100;
      };
      const nowX = x(now);
      const waits = [
        ...items("attention.changes").map((item) => ({ about: about(item), since: date(item.since) })),
        ...S.settled.map((z) => ({ about: z.label, since: date(z.since), done: true })),
      ].filter((w) => w.since).sort((a, b) => a.since - b.since).slice(0, 4);
      const bars = waits.map((w, i) => `<span class="wbar${w.done ? " done" : ""}" style="left:${x(w.since).toFixed(2)}%;width:${Math.max(0, nowX - x(w.since)).toFixed(2)}%;top:${i * 19 + 9}px"></span>
        <span class="wlab${w.done ? " done" : ""}" style="left:calc(${Math.min(nowX, 70).toFixed(2)}% + 10px);top:${i * 19 + 9}px">${esc(w.about)} <span class="muted num">since ${esc(when(w.since))}</span></span>`).join("");
      const isToday = (d) => d && parts(d).day === today;
      const ran = runs().filter((r) => isToday(date(r.started_at)))
        .map((r) => `<span class="rdot${r.kind === "failed" ? " fail" : ""}" style="left:${x(date(r.started_at)).toFixed(2)}%"></span>`).join("");
      const crew = items("activity.changes").map((item) => date(item.since)).filter(Boolean)
        .map((d) => `<span class="rspan" style="left:${x(d).toFixed(2)}%;width:${Math.max(0.5, nowX - x(d)).toFixed(2)}%"></span>`).join("");
      const next = items("schedules.changes").filter((s) => s.status === "active" && isToday(date(s.next_run_at)))
        .map((s) => `<span class="rdot next" style="left:${x(date(s.next_run_at)).toFixed(2)}%" title="${esc(text(s.name))}"></span>`).join("");
      const ticks = [6, 9, 12, 15, 18, 21, 24].map((h, i, a) => {
        const at = ((h * 60 - START) / (END - START)) * 100;
        return Math.abs(at - nowX) < 6 ? "" : `<span class="${i === 0 ? "first" : i === a.length - 1 ? "last" : ""}${i % 2 ? " odd" : ""}" style="left:${at}%">${String(h).padStart(2, "0")}:00</span>`;
      }).join("");
      const waiting = waits.filter((w) => !w.done);
      return {
        meta: `${held("attention.changes").size} waiting · ${held("runs.changes").size} runs`,
        body: `<div class="day"><div class="day-l"><span>Waits on you</span><span>Ran on its own</span></div>
          <div class="day-p" role="img" aria-label="${esc(waiting.map((w) => `${w.about} has waited since ${when(w.since)}`).join("; ") || "Nothing waits on you")}">
            <div class="lane-w">${bars}</div><div class="lane-r">${ran}${crew}${next}</div>
            <div class="axis">${ticks}<span class="nowt" style="left:${nowX.toFixed(2)}%">${esc(hm(now))}</span></div><span class="nowl" style="left:${nowX.toFixed(2)}%"></span></div></div>`,
      };
    },
  };

  // Bytes as the design says them: "38 of 100 GB".
  function storage(used, cap) {
    const top = cap || used;
    const [unit, name] = top >= 1e9 ? [1e9, "GB"] : top >= 1e6 ? [1e6, "MB"] : [1e3, "KB"];
    const f = (v) => new Intl.NumberFormat(zone().locale, { maximumFractionDigits: v / unit < 10 ? 1 : 0 }).format(v / unit);
    return cap ? `${f(used)} of ${f(cap)} ${name}` : `${f(used)} ${name} used`;
  }

  // A failed run that started on its own, not one inside another, offers
  // Retry here, unless it waits on you, where the queue offers it.
  function runRow(r, t) {
    const id = text(r.execution_id);
    const waiting = r.kind === "failed" && waitsOn(id);
    const retry = r.kind === "failed" && !text(r.parent_execution_id) && !waiting;
    const note = said(`run:${id}`);
    const sub = note || (waiting ? `<span class="mark">← waits on you</span>`
      : retry ? `<span class="neg-t">failed</span>${cause(r.error) ? ` · ${esc(cause(r.error))}` : ""}`
      : r.kind === "failed" ? esc(cause(r.error) || "failed")
      : firedBy(r) ? "Scheduled" : esc(capital(text(r.component_type) || "run")));
    const out = retry ? retryButton(id, runName(r), `rt-${esc(id)}`, " sm")
      : r.kind === "completed" ? `<span class="out"><b>ok</b><span class="muted num">${duration(r.duration_ms)}</span></span>`
      : r.kind === "failed" ? `<span class="out"><b class="neg-t">failed</b><span class="muted">${esc(text(isItem(r.error) ? r.error.class : ""))}</span></span>`
      : r.kind === "cancelled" ? `<span class="out"><b>stopped</b></span>` : `<span class="out"><span><span class="dot run"></span> running</span></span>`;
    return `<li class="row log"><span class="t">${t}</span>
      <button class="row-btn" data-act="page" data-page="executions" data-key="run-${esc(id)}"><span class="row-t">${esc(runName(r))}</span><span class="row-s${note ? " said" : ""}">${sub}</span></button>
      ${out}</li>`;
  }

  // A feed's last result, field by field: the first number large, the
  // other plain values as a list, a list of values as a row. The page knows
  // no feed's own shape, so it draws what the result holds.
  function feedCard(name) {
    const f = feed(name);
    if (!f) return { body: `<p class="empty">No ${esc(name)} feed has sent a result yet. Ask AQUA to set one up named “${esc(name)}”.</p>` };
    const busy = S.busy[`feed:${name}`];
    const actions = Array.isArray(f.actions) ? f.actions.filter((a) => isItem(a) && text(a.name)) : [];
    const refresh = actions.find((a) => a.name === "refresh");
    const others = actions.filter((a) => a !== refresh);
    const tools = refresh ? `<button class="ib" data-act="feed" data-feed="${name}" data-action="refresh" data-key="fr-${name}" aria-label="Refresh ${esc(name)}" title="${esc(text(refresh.label) || "Refresh")}"${busy ? ' aria-disabled="true"' : ""}>${ic("refresh")}</button>` : "";
    const meta = [text(f.label), busy ? "Refreshing" : f.at ? `at ${when(f.at)}` : ""].filter(Boolean).map(esc).join(" · ");
    const result = isItem(f.result) ? f.result : { value: f.result };
    // The hero is the number of the largest size, so a temperature stands
    // over its wind and a price over its change.
    const numbers = Object.entries(result).filter(([, v]) => typeof v === "number" && Number.isFinite(v));
    const hero = numbers.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))[0] || null;
    const plain = [], lists = [];
    for (const [k, v] of Object.entries(result)) {
      if (hero && k === hero[0]) continue;
      if (["string", "number", "boolean"].includes(typeof v)) plain.push([k, v]);
      else if (Array.isArray(v) && v.length) lists.push([k, v]);
    }
    const list = lists[0];
    const value = (v) => (typeof v === "boolean" ? (v ? "yes" : "no") : typeof v === "number" ? nf().format(v)
      : typeof v === "string" && ISO_TIME.test(v) ? when(v) : text(v));
    const pieces = (v) => (isItem(v) ? Object.values(v).filter((x) => ["string", "number"].includes(typeof x)).slice(0, 2).map(value) : [value(v)]);
    const body = [
      hero ? `<p class="f-hero"><span class="f-big">${esc(value(hero[1]))}</span><span class="f-key">${esc(human(hero[0]))}</span></p>` : "",
      plain.length ? `<dl class="kv">${plain.slice(0, list ? 2 : 4).map(([k, v]) => `<dt>${esc(human(k))}</dt><dd>${esc(value(v))}</dd>`).join("")}</dl>` : "",
      list ? `<ol class="f-list" aria-label="${esc(human(list[0]))}">${list[1].slice(0, 4).map((v) => `<li>${pieces(v).map((c, i) => `<span class="${i ? "" : "muted "}num">${esc(c)}</span>`).join("")}</li>`).join("")}</ol>` : "",
      others.length ? `<div class="f-acts">${others.slice(0, 3).map((a) => `<button class="btn" data-act="feed" data-feed="${name}" data-action="${esc(a.name)}" data-key="fa-${name}-${esc(a.name)}"${busy ? ' aria-disabled="true"' : ""}>${esc(text(a.label) || human(a.name))}</button>`).join("")}</div>` : "",
    ].join("");
    return { meta, tools, body: body || `<p class="empty">The last result holds nothing to show.</p>` };
  }

  function appMark(a) {
    const icon = typeof a.icon === "string" ? a.icon : "";
    if (icon && [...icon].length <= 2 && /[^\x00-\x7f]/.test(icon)) return icon;
    return ([...text(a.name)][0] || "?").toUpperCase();
  }

  function widget(id) {
    const w = WIDGETS[id], r = R[id]();
    const H = w.side === "near" ? "h2" : "h3";
    const tools = S.arranging
      ? `<span class="arrange-bar"><button class="ib" data-act="move" data-dir="-1" data-id="${id}" data-key="up-${id}" aria-label="Move ${w.title} up">${ic("up")}</button>
          <button class="ib" data-act="move" data-dir="1" data-id="${id}" data-key="down-${id}" aria-label="Move ${w.title} down">${ic("down")}</button>
          <button class="switch" role="switch" aria-checked="true" data-act="toggle" data-id="${id}" data-key="tg-${id}" aria-label="Show ${w.title}"></button></span>`
      : `${r.tools || ""}${askBtn(id, w.title.toLowerCase())}`;
    return `<article class="w w-${w.side}${w.size ? ` w-${w.size}` : ""}" data-w="${id}" aria-labelledby="h-${id}">
      <header class="w-head">${S.arranging ? `<span class="grip">${ic("grip", "s")}</span>` : ""}<${H} class="w-title" id="h-${id}">${w.title}</${H}>
        <span class="w-meta">${S.arranging ? "" : r.meta || ""}</span><span class="w-tools">${tools}</span></header>
      <div class="w-body">${under(worst(READS[id]), r.body, r.kept)}</div></article>`;
  }

  // How the place stands, as the design's subline says it: from the
  // system's status once it is read, else from the schedules and the crew.
  function standing() {
    const s = one("system.changes");
    if (s) {
      const ready = count(s.crew_ready), total = count(s.crew_total);
      const line = [
        HEALTH[s.health] ? HEALTH[s.health].words : "",
        typeof s.model_connected === "boolean" ? `model ${s.model_connected ? "connected" : "not connected"}` : "",
        ready !== null && total !== null ? `crew ${ready} of ${total}` : "",
      ].filter(Boolean).join(" · ");
      const st = worst(["system.changes"]);
      if (line) return esc(st ? `${line} · ${stateWords(st).charAt(0).toLowerCase()}${stateWords(st).slice(1)}` : line);
    }
    const active = items("schedules.changes").filter((h) => h.status === "active").length;
    const jobs = held("activity.changes").size;
    return `${active} ${plural(active, "schedule", "schedules")} running · crew: ${jobs ? `${jobs} at work` : "idle"}`;
  }

  function farHead() {
    const sub = S.note ? `<span class="note">${esc(S.note)}</span>`
      : S.arranging ? (S.saved ? `Saved to your preferences at ${esc(hm(S.saved))}` : "Drag a widget by its title, or use the arrows")
      : standing();
    const off = DEFAULT_ORDER.filter((id) => !isOn(id));
    return `<div class="far-head"><div><h2 id="far-title">Running on its own</h2><p class="far-sub">${sub}</p></div>
        <button class="btn${S.arranging ? " primary" : ""}" data-act="arrange" data-key="arrange">${S.arranging ? "Done" : "Arrange"}</button></div>
      ${S.arranging ? `<div class="offrow"><h3>Off</h3>${off.length ? off.map((id) => `<button class="chip" data-act="toggle" data-id="${id}" data-key="tg-${id}" aria-label="Show ${WIDGETS[id].title}">${ic("plus", "s")}${WIDGETS[id].title}</button>`).join("") : `<span class="muted">Every widget is on</span>`}</div>` : ""}`;
  }

  function render() {
    doc.classList.toggle("arranging", S.arranging);
    doc.classList.toggle("frozen", !S.live);
    const keep = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
    try {
      $("#near").innerHTML = queue() + shown("near").map(widget).join("");
      $("#far").innerHTML = farHead() + `<div class="grid" data-side="far">${shown("far").map(widget).join("")}</div>`;
    } catch (_e) {
      return plainList();
    }
    clearCovered();
    if (keep) {
      const el = document.querySelector(`[data-key="${CSS.escape(keep)}"]`);
      if (el) el.focus({ preventScroll: true });
    }
  }

  // Drawing failed: the data as a plain list, with nothing to press.
  function plainList() {
    const li = (s) => `<li>${esc(s)}</li>`;
    const waiting = items("attention.changes").map((item) => `${about(item)} (${text(item.kind).replace(/_/g, " ")}, since ${when(item.since)})`);
    const schedules = items("schedules.changes").map((item) => `${text(item.name)}: ${text(item.status)}`);
    const ran = runs().map((r) => `${runName(r)}: ${text(r.kind)}`);
    const s = one("system.changes");
    const system = s ? [HEALTH[s.health] ? HEALTH[s.health].words : text(s.health), text(s.version) && `CYFR ${text(s.version)}`,
      s.update_available === true && "update available"].filter(Boolean) : [];
    $("#frame").innerHTML = `<div class="plain"><h2>Waits on you</h2><ul>${waiting.map(li).join("") || li("Nothing")}</ul>
      <h2>Schedules</h2><ul>${schedules.map(li).join("") || li("None")}</ul><h2>Runs</h2><ul>${ran.map(li).join("") || li("None")}</ul>
      <h2>System</h2><ul>${system.map(li).join("") || li("Not read yet")}</ul></div>`;
  }

  // The windows over the desktop cover a part of it, in its own pixels:
  // the far side keeps its widgets clear of the part at its right edge.
  function clearCovered() {
    const frame = $("#frame");
    if (!frame) return;
    let c = 0;
    if (size() !== "phone") {
      const far = $("#far").getBoundingClientRect();
      for (const r of S.covered) {
        const overlaps = r.y < far.bottom && r.y + r.height > far.top && r.x + r.width > far.left && r.x < far.right;
        if (overlaps && r.x > far.left + 260) c = Math.max(c, far.right - r.x);
      }
    }
    frame.style.setProperty("--covered", `${Math.round(c)}px`);
  }

  let pending = false;
  // A change draws on the next frame while the desktop is shown; a frozen
  // one draws once it is shown again.
  function changed() {
    if (!S.live || pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      render();
    });
  }

  // ------------------------------------------------------------ crossing

  // An item that left the queue live is settled: it crosses the line.
  function settle(id, outcome) {
    const s = BY["attention.changes"], item = s.items.get(id);
    if (!item) return;
    cross(id, () => {
      s.items.delete(id);
      S.settled.unshift({ id, label: about(item), since: item.since, at: new Date(), what: settledWhat(item.kind, outcome),
        out: outcome === "expired" || outcome === "withdrawn" ? outcome : "settled" });
      S.settled.length = Math.min(S.settled.length, 10);
    });
  }

  const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  // A settled item leaves the near side and lands in today's log.
  function cross(id, mutate) {
    const row = document.querySelector(`[data-att="${CSS.escape(id)}"]`);
    const from = row && row.getBoundingClientRect();
    const ghost = row && row.cloneNode(true);
    mutate();
    if (!S.live) return;
    pending = false;
    render();
    const target = document.querySelector(`[data-land="${CSS.escape(id)}"]`);
    if (!row || !target || reduced() || !ghost.animate) return;
    const to = target.getBoundingClientRect();
    if (to.top < 0 || to.bottom > innerHeight || from.width === 0) return;
    ghost.classList.add("ghost");
    ghost.removeAttribute("data-att");
    ghost.querySelectorAll("[data-act]").forEach((b) => b.removeAttribute("data-act"));
    Object.assign(ghost.style, { left: `${from.left}px`, top: `${from.top}px`, width: `${from.width}px`, height: `${from.height}px` });
    document.body.append(ghost);
    target.style.opacity = "0";
    const sx = to.width / from.width, sy = to.height / from.height;
    const anim = ghost.animate([
      { transform: "translate(0,0) scale(1,1)", opacity: 1 },
      { transform: `translate(${(to.left - from.left) / 2}px,${(to.top - from.top) / 2 - 24}px) scale(${(1 + sx) / 2},${(1 + sy) / 2})`, opacity: 1, offset: 0.5 },
      { transform: `translate(${to.left - from.left}px,${to.top - from.top}px) scale(${sx},${sy})`, opacity: 0.2 },
    ], { duration: 720, easing: "cubic-bezier(.3,.7,.2,1)", fill: "forwards" });
    anim.onfinish = () => {
      ghost.remove();
      target.style.opacity = "";
      target.classList.add("landed");
    };
  }

  // ---------------------------------------------------------------- taps

  function note(key, words, ok = false, ms = NOTE_MS) {
    const said = { words, ok };
    S.notes[key] = said;
    setTimeout(() => {
      if (S.notes[key] !== said) return;
      delete S.notes[key];
      changed();
    }, ms);
  }

  // A schedule run that failed before any occurrence: a notice on its row.
  function scheduleNotice(item) {
    const id = text(item.schedule_id);
    if (!id || item.kind !== "failed") return;
    const why = cause(item.reason);
    note(`sch:${id}`, `Did not start${why ? ` · ${why}` : ""}`, false, SAID_MS);
  }

  function press(control, id) {
    const key = `sch:${id}`;
    S.busy[key] = true;
    changed();
    sdk.press(control, id).then((answer) => {
      delete S.busy[key];
      if (answer.outcome === "refused") note(key, `Refused · ${text(answer.reason) || "refused"}`);
      else if (answer.outcome === "cancelled") note(key, answer.reason === "too_soon" ? "Not sent · too soon after your last tap" : "Not sent · tap again");
      changed();
    });
  }

  // One press per tap, the button waiting until its answer.
  function retry(id) {
    const key = `run:${id}`;
    if (!id || S.busy[key]) return;
    S.busy[key] = true;
    changed();
    const answered = (answer) => {
      delete S.busy[key];
      const outcome = answer && answer.outcome;
      if (outcome === "accepted") note(key, "Running again", true, SAID_MS);
      else if (outcome === "cancelled") note(key, answer.reason === "too_soon" ? "Too soon after your last tap. Tap again in a moment" : "Nothing ran", false, SAID_MS);
      else note(key, RETRY_SAID[answer && answer.reason] || "It could not run again", false, SAID_MS);
      changed();
    };
    sdk.press(RETRY, id).then(answered, () => answered(null));
  }

  function pressFeed(name, actionName) {
    const f = feed(name);
    if (!f || !text(f.binding)) return;
    const key = `feed:${name}`;
    S.busy[key] = true;
    sdk.press(f.binding, actionName);
    setTimeout(() => {
      if (S.busy[key]) {
        delete S.busy[key];
        changed();
      }
    }, 15000);
    changed();
  }

  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-act]");
    if (!b || !sdk || b.getAttribute("aria-disabled") === "true") return;
    const { act, id } = b.dataset;
    switch (act) {
      // A page at its record when the control names one: AQUA's panel at an
      // own thread, the chat at a shared one, a Dashboard page at its top.
      case "page": return b.dataset.ref ? sdk.settings(b.dataset.page, b.dataset.ref) : sdk.settings(b.dataset.page);
      case "grant": return sdk.grant(b.dataset.ref);
      case "open": return sdk.open(b.dataset.ref);
      case "ask": return sdk.ask(id);
      case "press": return press(b.dataset.control, id);
      case "retry": return retry(id);
      case "feed": return pressFeed(b.dataset.feed, b.dataset.action);
      case "arrange": S.arranging = !S.arranging; S.note = null; return render();
      case "move": return move(id, Number(b.dataset.dir));
      case "toggle": return toggle(id);
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && S.arranging) {
      S.arranging = false;
      render();
    }
  });

  // Long-press a widget's title to arrange; while arranging, drag it by its
  // title within its side, and the order is written when it is dropped.
  let hold = null, drag = null;
  document.addEventListener("pointerdown", (e) => {
    const head = e.target.closest(".w[data-w] .w-head");
    if (!head || e.target.closest("button")) return;
    const w = head.closest(".w");
    if (!S.arranging) {
      hold = setTimeout(() => {
        S.arranging = true;
        render();
      }, 550);
      return;
    }
    drag = { w, side: w.parentElement, id: w.dataset.w };
    w.classList.add("dragging");
    head.setPointerCapture(e.pointerId);
    e.preventDefault();
  });
  document.addEventListener("pointermove", (e) => {
    if (hold && Math.abs(e.movementX) + Math.abs(e.movementY) > 6) {
      clearTimeout(hold);
      hold = null;
    }
    if (!drag) return;
    drag.w.style.pointerEvents = "none";
    const over = document.elementFromPoint(e.clientX, e.clientY);
    drag.w.style.pointerEvents = "";
    const t = over && over.closest(".w[data-w]");
    if (!t || t === drag.w || t.parentElement !== drag.side) return;
    const kids = [...drag.side.querySelectorAll(":scope > .w[data-w]")];
    drag.side.insertBefore(drag.w, kids.indexOf(drag.w) < kids.indexOf(t) ? t.nextSibling : t);
  });
  const endHold = () => {
    clearTimeout(hold);
    hold = null;
    if (!drag) return;
    const list = [...drag.side.querySelectorAll(":scope > .w[data-w]")].map((x) => x.dataset.w);
    drag.w.classList.remove("dragging");
    const sideName = WIDGETS[drag.id].side;
    drag = null;
    if (list.join() !== shown(sideName).join()) reorder(sideName, list);
    render();
  };
  document.addEventListener("pointerup", endHold);
  document.addEventListener("pointercancel", endHold);

  let lastSize = size();
  addEventListener("resize", () => {
    if (size() !== lastSize) {
      lastSize = size();
      render();
    } else clearCovered();
  });

  // ------------------------------------------------------- what the shell says

  function desktop(value) {
    if (!isItem(value)) return;
    if (isItem(value.prefs) && isItem(value.prefs.document)) S.prefs = value.prefs.document;
    if (isItem(value.appearance)) S.appearance = value.appearance;
    S.person = isItem(value.person) && typeof value.person.name === "string" && value.person.name ? value.person.name : null;
    doc.dataset.theme = S.appearance.mode === "dark" ? "dark" : "light";
    if (S.appearance.locale) doc.lang = S.appearance.locale;
    changed();
  }

  let tick = null;
  function state(value) {
    S.live = value !== "frozen";
    clearInterval(tick);
    tick = null;
    if (S.live) {
      tick = setInterval(changed, 30000);
      changed();
    } else doc.classList.add("frozen");
  }

  function start() {
    if (!sdk) {
      render();
      return;
    }
    if (sdk.desktop) desktop(sdk.desktop);
    sdk.on("desktop", desktop);
    sdk.on("installed", (list) => {
      S.installed = Array.isArray(list) ? list.filter((a) => isItem(a) && typeof a.ref === "string" && typeof a.name === "string") : [];
      changed();
    });
    sdk.on("covered", (rects) => {
      S.covered = Array.isArray(rects) ? rects.filter((r) => isItem(r) && ["x", "y", "width", "height"].every((k) => Number.isFinite(r[k]))) : [];
      clearCovered();
    });
    sdk.on("posture", changed);
    sdk.on("state", state);
    state("live");
    render();
    Promise.race([Promise.allSettled(STREAMS.map(open)), pause(READY_MS)]).then(() => {
      render();
      sdk.ready();
    });
  }

  start();
})();

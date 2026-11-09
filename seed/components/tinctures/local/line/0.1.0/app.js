// The decision line: what waits on the person's tap on the near side, what
// their CYFR runs on its own on the far side; a settled item crosses the
// line into today's log.
//
// Everything the page shows comes from the streams its manifest declares,
// the current state first and then changes, and from what the shell tells
// it (installed apps, posture, covered rects, live or frozen, the desktop's
// preferences, appearance and the person's name). It acts only through the
// shell's verbs, each on a tap: a control press (pause, resume), a
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
    schedules: { side: "far", title: "Schedules" },
    today: { side: "far", title: "Today" },
    vault: { side: "far", title: "Vault" },
    day: { side: "far", title: "The day", size: "wide" },
  };
  const DEFAULT_ORDER = Object.keys(WIDGETS);
  // Which widgets are on at each screen size until the person says
  // otherwise: the carried screen fits everything it shows in 600 pixels,
  // and each size's widgets read five streams (STREAMS).
  const DEFAULT_ON = {
    phone: ["apps", "weather", "schedules", "today"],
    carried: ["apps", "weather", "schedules", "today"],
    desk: ["apps", "weather", "schedules", "today", "day"],
  };
  // How many rows a list shows before "all", per size.
  const CAP = { phone: 6, carried: 4, desk: 6 };
  const PAUSE = "pause-schedule";
  const RESUME = "resume-schedule";
  const MAX_RUNS = 20;
  const RETRY_MS = [2000, 5000, 15000, 60000];
  // How long one open waits for the one before it, and how long the first
  // draw waits for the opens before the page tells the shell it is ready,
  // well inside the ten seconds the shell gives it.
  const OPEN_STEP_MS = 1500;
  const READY_MS = 6000;
  const NOTE_MS = 4000;
  // The refusal classes a grant can fix, and the cause a run's error reads
  // as for them, as the shipped canvas reads them.
  const GRANTABLE = ["consent_required", "setup_required"];
  const GRANT_CAUSES = ["needs_setup"];
  const CAUSES = {
    needs_setup: "needs setup", unavailable: "unavailable", timed_out: "timed out",
    cancelled: "cancelled", rate_limited: "rate limited", refused: "refused",
    bad_input: "bad input", not_found: "not found", waits_for_you: "waits for you",
  };

  const S = {
    attention: new Map(), // id -> {item, open}
    runs: [], // one per execution, latest change first
    schedules: new Map(), // schedule_id -> {item, open}
    activity: new Map(), // job id -> {item, open}
    threads: new Map(), // id -> {item, open}
    vault: new Map(), // name -> {item, open}
    feeds: { weather: null, vpn: null },
    refusals: {},
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
    busy: {}, // a pressed schedule or feed, until its stream moves
    notes: {}, // a refused press's reason, by row
  };
  let seq = 0;

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
    for (const { item } of S.schedules.values()) {
      if (componentRef(text(item.reference)) === ref && text(item.name)) return text(item.name);
    }
    return componentName(reference);
  }
  const runName = (run) => refName(text(run.reference));
  const grantable = (error) => isItem(error) && (GRANTABLE.includes(error.class) || GRANT_CAUSES.includes(error.cause));
  const lastFailure = (reference) => S.runs.find((r) => r.kind === "failed" && text(r.reference) === reference) || null;
  const cause = (error) => (isItem(error) ? CAUSES[error.cause] || text(error.class) : "");

  // The streams this page opens, how each item folds into the state, and
  // the widgets that read each. A browser keeps six connections to one host
  // over plain HTTP and each open stream holds one, so the page holds at
  // most five open: the queue's, the schedules' and the runs', always,
  // then the shown widgets' in the order they stand. A stream no shown
  // widget reads stays closed, each size's default widgets read five, and
  // a widget past the five says so in its place.
  const STREAMS = [
    { name: "attention.changes", subject: null, item: attentionItem, opened: (n) => prune(S.attention, n) },
    { name: "runs.changes", subject: null, item: runItem },
    { name: "schedules.changes", subject: null, item: keyed(S.schedules, "schedule_id", (i) => i.kind === "removed"), opened: (n) => prune(S.schedules, n) },
    { name: "threads.changes", subject: null, for: ["threads"], item: keyed(S.threads, "id", (i) => i.kind === "removed"), opened: (n) => prune(S.threads, n) },
    { name: "feed.results", subject: "weather", for: ["weather"], item: feedItem("weather") },
    { name: "feed.results", subject: "vpn", for: ["vpn"], item: feedItem("vpn") },
    { name: "activity.changes", subject: null, for: ["today", "day"], item: keyed(S.activity, "id", (i) => i.kind === "ended"), opened: (n) => prune(S.activity, n) },
    { name: "vault.changes", subject: null, for: ["vault"], item: keyed(S.vault, "name", (i) => i.kind === "removed"), opened: (n) => prune(S.vault, n) },
  ];
  const label = (stream) => (stream.subject ? `${stream.name}:${stream.subject}` : stream.name);
  const MAX_OPEN = 5;
  const LIMITED = "This desktop reads five things at once. Turn another widget off to show this one.";

  // An item kept as its key's latest state; `gone` says it left.
  function keyed(map, key, gone) {
    return (item, open) => {
      const id = text(item[key]);
      if (!id) return;
      if (gone(item)) map.delete(id);
      else map.set(id, { item, open });
    };
  }
  // A reopened stream's refresh holds everything there is, so what an
  // earlier open delivered and this one did not left in between.
  function prune(map, open) {
    for (const [id, held] of map) if (held.open < open) map.delete(id);
  }

  function attentionItem(item, open, fresh) {
    const id = text(item.id);
    if (!id) return;
    if (item.kind !== "removed") return void S.attention.set(id, { item, open });
    const held = S.attention.get(id);
    if (!held) return;
    if (fresh) return void S.attention.delete(id);
    cross(id, () => {
      S.attention.delete(id);
      S.settled.unshift({ id, label: about(held.item), since: held.item.since, at: new Date(), what: settledWhat(held.item.kind) });
      S.settled.length = Math.min(S.settled.length, 10);
    });
  }

  // One entry per run, the latest change first. A start that races the
  // refresh keeps a run's outcome; a run heard live keeps when it was heard.
  function runItem(item, _open, fresh) {
    const id = item.execution_id;
    if (typeof id !== "string") return;
    const before = S.runs.find((r) => r.execution_id === id);
    if (before && before.kind !== "started" && item.kind === "started") return;
    const heard = fresh ? (before && before.heard) || null : new Date();
    const run = { ...item, heard, seq: before ? before.seq : ++seq };
    S.runs = [run, ...S.runs.filter((r) => r.execution_id !== id)].slice(0, MAX_RUNS);
    if (S.busy[`run:${id}`]) delete S.busy[`run:${id}`];
  }

  function feedItem(name) {
    return (item) => {
      const held = S.feeds[name];
      if (held && typeof held.revision === "number" && typeof item.revision === "number" && item.revision <= held.revision) return;
      S.feeds[name] = item;
      delete S.busy[`feed:${name}`];
    };
  }

  // ---------------------------------------------------- keeping streams

  const followers = new Map();

  // Keeps one declared stream open: an ended stream opens again after a
  // pause and starts again with its refresh. Until it has opened once, a
  // refusal is final and shown in place of its widget; an open the
  // endpoint gave no answer on is tried again.
  function follow(stream) {
    let stopped = false, opens = 0, everOpened = false, current = null, timer;
    const follower = { refused: false };
    async function open() {
      const n = ++opens;
      const handle = await sdk.stream(stream.name, stream.subject, ({ data }) => {
        if (stopped || n !== opens || !isItem(data)) return;
        stream.item(data, n, data.refresh === true);
        changed();
      });
      if (stopped) return handle.close();
      everOpened = true;
      current = handle;
      delete S.refusals[label(stream)];
      if (stream.opened) stream.opened(n);
      changed();
      handle.closed.catch(() => {}).then(() => {
        if (current === handle) {
          current = null;
          retry(0);
        }
      });
    }
    function failed(error, attempt) {
      if (stopped) return;
      if (!everOpened && !(error && error.code === "unavailable")) {
        follower.refused = true;
        S.refusals[label(stream)] = error && error.code === "rate_limited" ? LIMITED : (error && error.message) || "This could not be read.";
        changed();
      } else retry(attempt);
    }
    function retry(attempt) {
      if (stopped) return;
      clearTimeout(timer);
      timer = setTimeout(() => open().catch((e) => failed(e, Math.min(attempt + 1, RETRY_MS.length - 1))), RETRY_MS[attempt]);
    }
    follower.first = open().catch((e) => failed(e, 0));
    follower.stop = () => {
      stopped = true;
      clearTimeout(timer);
      if (current) current.close();
      current = null;
      delete S.refusals[label(stream)];
    };
    return follower;
  }

  // Opens what the shown widgets read and closes what none reads, one open
  // after another in the order the widgets stand (each waits for the one
  // before it a moment at most), so when CYFR's bound is reached it is the
  // last widget that says so. A stream refused before
  // is opened again, since turning a widget off may have made room.
  let opening = Promise.resolve();
  function sync() {
    const on = new Set([...shown("near"), ...shown("far")]);
    const order = [...shown("near"), ...shown("far")];
    const rank = (s) => (s.for ? Math.min(...s.for.map((id) => (on.has(id) ? order.indexOf(id) : Infinity))) : -1);
    const ranked = STREAMS.filter((s) => rank(s) !== Infinity).sort((a, b) => rank(a) - rank(b));
    const wanted = ranked.slice(0, MAX_OPEN);
    for (const s of ranked.slice(MAX_OPEN)) S.refusals[label(s)] = LIMITED;
    for (const s of STREAMS) {
      const held = followers.get(label(s));
      if (held && (!wanted.includes(s) || held.refused)) {
        held.stop();
        followers.delete(label(s));
      }
    }
    for (const s of wanted) {
      if (followers.has(label(s))) continue;
      const placeholder = { refused: false, stop() { this.cancelled = true; } };
      followers.set(label(s), placeholder);
      delete S.refusals[label(s)];
      opening = opening.then(() => {
        if (placeholder.cancelled || followers.get(label(s)) !== placeholder) return;
        const follower = follow(s);
        followers.set(label(s), follower);
        return Promise.race([follower.first, pause(OPEN_STEP_MS)]);
      });
    }
    return opening;
  }
  const reading = (name) => followers.has(name);
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

  const KIND = {
    failed_run: { icon: "alert", neg: true, what: (a) => {
      const err = lastFailure(text(a.id));
      return ["Run failed", when(a.since), err && cause(err.error)].filter(Boolean).join(" · ");
    } },
    failed_schedule: { icon: "clock", neg: true, what: (a) => `Schedule failed · ${when(a.since)}` },
    approval: { icon: "approve", what: (a) => `Approval · since ${when(a.since)}` },
    confirmation: { icon: "key", what: (a) => `Confirmation · since ${when(a.since)}` },
    file_offer: { icon: "offer", what: (a) => `File offer · since ${when(a.since)}` },
  };
  const PAGE_ACT = { chat: "Open chat", executions: "Open runs", schedules: "Open schedules", files: "Open files" };
  function about(a) {
    if (a.kind === "failed_run") return refName(text(a.id));
    return text(a.label) || { approval: "An approval", confirmation: "A confirmation", file_offer: "A file", failed_schedule: "A schedule" }[a.kind] || "Something";
  }
  function settledWhat(kind) {
    return { approval: "Approval left your queue", failed_run: "A later run settled it", failed_schedule: "Its next run settled it",
      confirmation: "Decided in CYFR's prompt", file_offer: "File offer left your queue" }[kind] || "Left your queue";
  }
  // The one thing each item offers: a grant where one fixes a failed run,
  // the page it waits on otherwise; a confirmation waits in CYFR's prompt.
  function action(a) {
    if (a.kind === "failed_run") {
      const run = lastFailure(text(a.id));
      if (run && grantable(run.error)) return { label: "Grant", act: "grant", ref: componentRef(text(a.id)), primary: true };
    }
    const dest = isItem(a.destination) ? a.destination : null;
    if (dest && dest.kind === "page" && PAGE_ACT[dest.page]) return { label: PAGE_ACT[dest.page], act: "page", page: dest.page, primary: false };
    return null;
  }
  const bySince = (a, b) => (date(a.since) || Infinity) - (date(b.since) || Infinity);

  function queue() {
    const items = [...S.attention.values()].map((h) => h.item).sort(bySince);
    const k = items.length;
    const refusal = S.refusals["attention.changes"];
    const name = S.person ? `${S.person}, y` : "Y";
    const title = refusal ? "What waits on you"
      : k ? `<span class="count">${k}</span> ${plural(k, "thing waits", "things wait")} on you` : "Nothing waits on you";
    const last = S.settled[0];
    const sub = k ? `Oldest since ${esc(when(items[0].since))}`
      : last ? `Last settled ${esc(hm(last.at))}: ${esc(last.label)}` : `${esc(name)}our CYFR carries on by itself`;
    const cap = size() === "phone" ? k : size() === "carried" ? 4 : 6;
    const rows = items.slice(0, cap).map((a) => {
      const K = KIND[a.kind] || KIND.approval, act = action(a);
      const button = act
        ? `<button class="btn${act.primary ? " primary" : ""}" data-act="${act.act}" data-page="${esc(act.page || "")}" data-ref="${esc(act.ref || "")}" data-key="q-${esc(a.id)}" aria-label="${esc(`${act.label}: ${about(a)}`)}">${esc(act.label)}</button>`
        : `<span class="row-r">In CYFR's prompt</span>`;
      return `<li class="q-row" data-att="${esc(a.id)}"><span class="q-kind${K.neg ? " neg" : ""}">${ic(K.icon)}</span>
        <div style="min-width:0"><span class="q-about">${esc(about(a))}</span><span class="q-what">${esc(K.what(a))}</span></div>${button}</li>`;
    }).join("");
    const body = refusal ? `<p class="refusal">${esc(refusal)}</p>`
      : k ? `<ol class="queue" aria-label="Oldest first">${rows}</ol>${k > cap ? `<p class="q-more">and ${k - cap} more, oldest first</p>` : ""}`
      : `<p class="q-empty">When a run fails, an approval waits or someone offers you a file, it waits here for your tap.</p>`;
    return `<div class="w w-queue"><div class="q-head"><div><h1 class="q-title">${title}</h1><p class="q-sub">${sub}</p></div>
      ${S.arranging ? "" : askBtn("queue", "what waits on you")}</div>${body}</div>`;
  }

  const askBtn = (id, what) => `<button class="ib" data-act="ask" data-id="${id}" data-key="ask-${id}" aria-label="Ask AQUA about ${esc(what)}" title="Ask AQUA">${ic("drop")}</button>`;
  const pageLink = (page, words, key) => `<button class="link" data-act="page" data-page="${page}" data-key="${key}">${esc(words)}</button>`;

  const R = {
    apps() {
      const apps = S.installed;
      const meta = apps.length ? `${apps.length} installed` : "";
      const body = apps.length === 0 ? `<p class="empty">No apps yet. Ask AQUA to make you one.</p>`
        : `<ul class="apps">${apps.map((a) => `<li><button class="app" data-act="open" data-ref="${esc(a.ref)}" data-key="app-${esc(a.ref)}" aria-label="Open ${esc(a.name)}${a.open ? " (open)" : ""}">
            <span class="app-ic">${esc(appMark(a))}</span><span class="app-name">${a.open ? '<span class="app-open" aria-hidden="true"></span>' : ""}${esc(a.name)}</span></button></li>`).join("")}</ul>`;
      return { meta, body };
    },
    threads() {
      const all = [...S.threads.values()].map((h) => h.item)
        .sort((a, b) => (date(b.last_activity) || 0) - (date(a.last_activity) || 0));
      const list = all.slice(0, 4);
      return {
        meta: all.length ? `${list.length} of ${all.length}` : "",
        tools: `<button class="btn sm" data-act="page" data-page="chat" data-key="all-threads">All threads</button>`,
        refusal: S.refusals["threads.changes"],
        body: list.length === 0 ? `<p class="empty">No threads yet.</p>` : `<ul class="rows">${list.map((t) => {
          const people = Array.isArray(t.people) ? t.people.length : 0;
          const who = t.kind === "own" ? "With AQUA" : `${people} ${plural(people, "person", "people")}`;
          const flag = t.waits_on_you === true ? ` · <span class="mark">waits on you</span>` : "";
          return `<li class="row"><button class="row-btn" data-act="page" data-page="chat" data-key="th-${esc(t.id)}">
            <span class="row-t">${esc(text(t.title) || "Untitled")}</span><span class="row-s">${who}${flag}</span></button>
            <span class="row-r num">${esc(when(t.last_activity))}</span></li>`;
        }).join("")}</ul>`,
      };
    },
    weather: () => feedCard("weather"),
    vpn: () => feedCard("vpn"),
    schedules() {
      const at = (s) => (s.status === "paused" ? Infinity : (date(s.next_run_at) || Infinity));
      const list = [...S.schedules.values()].map((h) => h.item).sort((a, b) => at(a) - at(b));
      const active = list.filter((s) => s.status === "active").length;
      const paused = list.filter((s) => s.status === "paused").length;
      const cap = CAP[size()];
      const n = nf();
      return {
        meta: list.length ? `${active} active · ${paused} paused` : "",
        refusal: S.refusals["schedules.changes"],
        body: list.length === 0 ? `<p class="empty">Nothing is scheduled. Ask AQUA to run something for you, say every morning at seven.</p>`
          : `<ul class="rows">${list.slice(0, cap).map((s) => {
            const id = text(s.schedule_id), busy = S.busy[`sch:${id}`], note = S.notes[`sch:${id}`];
            const errors = Number(s.error_count) || 0;
            const sub = note ? `<span class="note">Refused · ${esc(note)}</span>`
              : s.status === "paused" ? `Paused · last ${esc(when(s.last_run_at) || "never")} · ${n.format(Number(s.run_count) || 0)} runs`
              : `Next ${esc(when(s.next_run_at) || "not planned")}${errors ? ` · <span class="neg-t">${errors} ${plural(errors, "error", "errors")}</span>` : ""} · ${n.format(Number(s.run_count) || 0)} runs`;
            const control = s.status === "active" ? PAUSE : s.status === "paused" ? RESUME : null;
            const words = control === PAUSE ? (busy ? "Pausing" : "Pause") : busy ? "Resuming" : "Resume";
            const button = control ? `<button class="btn sm" data-act="press" data-control="${control}" data-id="${esc(id)}" data-key="sc-${esc(id)}" aria-label="${esc(`${words} ${text(s.name)}`)}"${busy ? ' aria-disabled="true"' : ""}>${words}</button>` : "";
            return `<li class="row"><button class="row-btn" data-act="page" data-page="schedules" data-key="sr-${esc(id)}"><span class="row-t">${esc(text(s.name) || refName(text(s.reference)))}</span><span class="row-s">${sub}</span></button>${button}</li>`;
          }).join("")}</ul>${list.length > cap ? `<p class="more">${pageLink("schedules", `All ${list.length} schedules`, "all-sch")}</p>` : ""}`,
      };
    },
    today() {
      const cap = CAP[size()];
      const rows = [
        ...S.runs.map((r) => {
          return { at: r.heard, seq: r.seq, html: (t) => runRow(r, t) };
        }),
        ...[...S.activity.values()].map(({ item: j }) => ({ at: date(j.since), seq: 0, html: (t) => `<li class="row log"><span class="t">${t}</span>
          <div style="min-width:0"><span class="row-t">${esc(text(j.member))}</span><span class="row-s">Crew${j.asked_by ? ` · for ${esc(text(j.asked_by))}` : ""}</span></div>
          <span class="out"><span><span class="dot run"></span> ${esc(text(j.status) || "working")}</span></span></li>` })),
        ...S.settled.map((x) => ({ at: x.at, seq: Infinity, html: (t) => `<li class="row log" data-land="${esc(x.id)}"><span class="t">${t}</span>
          <div style="min-width:0"><span class="row-t">${esc(x.label)}</span><span class="row-s">${esc(x.what)}</span></div><span class="out">settled</span></li>` })),
      ].sort((a, b) => (b.at ? b.at.getTime() : -1) - (a.at ? a.at.getTime() : -1) || b.seq - a.seq);
      const failed = S.runs.filter((r) => r.kind === "failed").length;
      return {
        meta: S.runs.length ? `${S.runs.length} ${plural(S.runs.length, "run", "runs")} · ${failed} failed` : "",
        refusal: S.refusals["runs.changes"],
        body: rows.length === 0 ? `<p class="empty">No runs yet. A run shows here as it happens.</p>`
          : `<ul class="rows">${rows.slice(0, cap).map((r) => r.html(r.at ? esc(when(r.at)) : "")).join("")}</ul>${rows.length > cap ? `<p class="more">${pageLink("executions", `All runs`, "all-runs")}</p>` : ""}`,
      };
    },
    vault() {
      const list = [...S.vault.values()].map((h) => h.item).sort((a, b) => text(a.name).localeCompare(text(b.name)));
      const need = list.filter((v) => v.status === "needs_reauthorisation").length;
      const cap = CAP[size()];
      return {
        meta: list.length ? `${list.length} ${plural(list.length, "entry", "entries")} · ${need} to look at` : "",
        refusal: S.refusals["vault.changes"],
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
        ...[...S.attention.values()].map(({ item }) => ({ about: about(item), since: date(item.since) })),
        ...S.settled.map((z) => ({ about: z.label, since: date(z.since), done: true })),
      ].filter((w) => w.since).sort((a, b) => a.since - b.since).slice(0, 4);
      const bars = waits.map((w, i) => `<span class="wbar${w.done ? " done" : ""}" style="left:${x(w.since).toFixed(2)}%;width:${Math.max(0, nowX - x(w.since)).toFixed(2)}%;top:${i * 19 + 9}px"></span>
        <span class="wlab${w.done ? " done" : ""}" style="left:calc(${Math.min(nowX, 70).toFixed(2)}% + 10px);top:${i * 19 + 9}px">${esc(w.about)} <span class="muted num">since ${esc(when(w.since))}</span></span>`).join("");
      const isToday = (d) => d && parts(d).day === today;
      const heard = S.runs.filter((r) => isToday(r.heard))
        .map((r) => `<span class="rdot${r.kind === "failed" ? " fail" : ""}" style="left:${x(r.heard).toFixed(2)}%"></span>`).join("");
      const crew = [...S.activity.values()].map(({ item }) => date(item.since)).filter(Boolean)
        .map((d) => `<span class="rspan" style="left:${x(d).toFixed(2)}%;width:${Math.max(0.5, nowX - x(d)).toFixed(2)}%"></span>`).join("");
      const next = [...S.schedules.values()].map(({ item }) => item).filter((s) => s.status === "active" && isToday(date(s.next_run_at)))
        .map((s) => `<span class="rdot next" style="left:${x(date(s.next_run_at)).toFixed(2)}%" title="${esc(text(s.name))}"></span>`).join("");
      const ticks = [6, 9, 12, 15, 18, 21, 24].map((h, i, a) => {
        const at = ((h * 60 - START) / (END - START)) * 100;
        return Math.abs(at - nowX) < 6 ? "" : `<span class="${i === 0 ? "first" : i === a.length - 1 ? "last" : ""}${i % 2 ? " odd" : ""}" style="left:${at}%">${String(h).padStart(2, "0")}:00</span>`;
      }).join("");
      const waiting = waits.filter((w) => !w.done);
      return {
        meta: `${S.attention.size} waiting · ${S.runs.length} runs`,
        body: `<div class="day"><div class="day-l"><span>Waits on you</span><span>Ran on its own</span></div>
          <div class="day-p" role="img" aria-label="${esc(waiting.map((w) => `${w.about} has waited since ${when(w.since)}`).join("; ") || "Nothing waits on you")}">
            <div class="lane-w">${bars}</div><div class="lane-r">${heard}${crew}${next}</div>
            <div class="axis">${ticks}<span class="nowt" style="left:${nowX.toFixed(2)}%">${esc(hm(now))}</span></div><span class="nowl" style="left:${nowX.toFixed(2)}%"></span></div></div>`,
      };
    },
  };

  function runRow(r, t) {
    const waiting = r.kind === "failed" && S.attention.has(text(r.reference));
    const sub = waiting ? `<span class="mark">← waits on you</span>`
      : r.kind === "failed" ? esc(cause(r.error) || "failed")
      : esc(capital(text(r.component_type) || "run"));
    const out = r.kind === "completed" ? `<b>ok</b><span class="muted num">${duration(r.duration_ms)}</span>`
      : r.kind === "failed" ? `<b class="neg-t">failed</b><span class="muted">${esc(text(isItem(r.error) ? r.error.class : ""))}</span>`
      : r.kind === "cancelled" ? `<b>stopped</b>` : `<span><span class="dot run"></span> running</span>`;
    return `<li class="row log"><span class="t">${t}</span>
      <button class="row-btn" data-act="page" data-page="executions" data-key="run-${esc(r.execution_id)}"><span class="row-t">${esc(runName(r))}</span><span class="row-s">${sub}</span></button>
      <span class="out">${out}</span></li>`;
  }

  // A feed's last result, field by field: the first number large, the
  // other plain values as a list, a list of values as a row. The page knows
  // no feed's own shape, so it draws what the result holds.
  function feedCard(name) {
    const f = S.feeds[name], refusal = S.refusals[`feed.results:${name}`];
    if (refusal) return { refusal, body: "" };
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
      <div class="w-body">${r.refusal ? `<p class="refusal">${esc(r.refusal)}</p>` : r.body}</div></article>`;
  }

  function farHead() {
    const active = [...S.schedules.values()].filter((h) => h.item.status === "active").length;
    const crew = reading("activity.changes") ? ` · crew: ${S.activity.size ? `${S.activity.size} at work` : "idle"}` : "";
    const sub = S.note ? `<span class="note">${esc(S.note)}</span>`
      : S.arranging ? (S.saved ? `Saved to your preferences at ${esc(hm(S.saved))}` : "Drag a widget by its title, or use the arrows")
      : `${active} ${plural(active, "schedule", "schedules")} running${crew}`;
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
    const items = [...S.attention.values()].map(({ item }) => `${about(item)} (${text(item.kind).replace(/_/g, " ")}, since ${when(item.since)})`);
    const schedules = [...S.schedules.values()].map(({ item }) => `${text(item.name)}: ${text(item.status)}`);
    const runs = S.runs.map((r) => `${runName(r)}: ${text(r.kind)}`);
    $("#frame").innerHTML = `<div class="plain"><h2>Waits on you</h2><ul>${items.map(li).join("") || li("Nothing")}</ul>
      <h2>Schedules</h2><ul>${schedules.map(li).join("") || li("None")}</ul><h2>Runs</h2><ul>${runs.map(li).join("") || li("None")}</ul></div>`;
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

  function note(key, reason) {
    S.notes[key] = reason;
    setTimeout(() => {
      delete S.notes[key];
      changed();
    }, NOTE_MS);
  }

  function press(control, id) {
    const key = `sch:${id}`;
    S.busy[key] = true;
    changed();
    sdk.press(control, id).then((answer) => {
      delete S.busy[key];
      if (answer.outcome === "refused") note(key, text(answer.reason) || "refused");
      else if (answer.outcome === "cancelled") note(key, "tap again");
      changed();
    });
  }

  function pressFeed(name, actionName) {
    const f = S.feeds[name];
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
      case "page": return sdk.settings(b.dataset.page);
      case "grant": return sdk.grant(b.dataset.ref);
      case "open": return sdk.open(b.dataset.ref);
      case "ask": return sdk.ask(id);
      case "press": return press(b.dataset.control, id);
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
      if (started) sync();
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
    if (started) sync();
    changed();
  }

  let tick = null;
  let started = false;
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
    started = true;
    Promise.race([sync(), pause(READY_MS)]).then(() => {
      render();
      sdk.ready();
    });
  }

  start();
})();

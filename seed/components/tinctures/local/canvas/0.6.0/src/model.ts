// Everything the canvas does apart from drawing: the SDK calls, the streams
// it keeps open, and how each stream's events fold into the state App.tsx
// draws. Its TypeScript is types only, so the canvas's tests run this file
// as it is.

// window.cyfr on a canvas, as the SDK declares it (apps/cyfr/assets/js/sdk/client.js).
export interface Sdk {
  // Answers the function that stops the handler hearing more.
  on(
    event: "installed" | "covered" | "posture" | "state" | "desktop",
    handler: (value: unknown) => void
  ): (() => void) | void;
  // Besides each change, the handler hears the delivery contract's
  // `snapshot`, `resync`, `stale`, `unavailable` and `denied`.
  stream(name: string, subject: string | null, onEvent: (event: StreamEvent) => void): Promise<StreamHandle>;
  open(ref: string): void;
  grant(ref: string): void;
  // One of CYFR's own pages by its key, or `aqua` or `chat`, at the
  // record `ref` names where the page has one.
  settings(page: string, ref?: string | null): void;
  // An act only the person may do, decided in CYFR's own prompt.
  request(operation: string, args?: Record<string, unknown>): Promise<Decided> & { requested: Promise<string | null> };
  // A control the canvas declares, with the value its pick takes.
  press(control: string, value: string | null): Promise<Pressed>;
  // Each widget the document names replaces that widget's whole entry.
  prefs(document: { widgets: Record<string, { on: boolean }> }): Promise<Written>;
  // `prefs` is the person's preferences document for this canvas, null
  // until the canvas's open arrives.
  readonly desktop: { prefs: { document: unknown; revision: number } } | null;
  ready(): void;
}

// An event of a stream: a change carries its `revision` and `at`; a
// delivery event names itself in `event`, with `revision` null.
export interface StreamEvent {
  id: number | null;
  event: string;
  data: unknown;
  revision?: number | null;
  at?: string | null;
}

// `suspended` while the canvas is hidden, opened again once it is shown.
export type StreamState = "live" | "unavailable" | "suspended" | "stale" | "denied" | "ended";

export interface StreamHandle {
  close(): void;
  closed: Promise<void>;
  readonly state: StreamState;
}

export interface Pressed {
  outcome: "accepted" | "refused" | "cancelled";
  reason?: string;
}

// A request's decision: `approved` once what was asked ran.
export interface Decided {
  outcome: "approved" | "refused" | "cancelled";
  reason?: string;
}

// A write's answer: on `stale`, `document` is the one another write left.
export interface Written {
  outcome: "saved" | "stale" | "refused" | "cancelled";
  document?: unknown;
  revision?: number;
  reason?: string;
}

export interface InstalledApp {
  ref: string;
  name: string;
  // The manifest's emoji, or null for an app that names none.
  icon: string | null;
  // Whether the app is open on this canvas, minimised included.
  open: boolean;
}

// A rectangle of the canvas's own page, in CSS pixels.
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type Posture = "desk" | "hand";

// One event's data: the stream's fields, as JSON.
export type Item = Record<string, unknown>;

export interface State {
  apps: InstalledApp[];
  // One entry per run, the latest change first.
  runs: Item[];
  // By schedule id.
  schedules: Map<string, { schedule: Item }>;
  // The last schedule runs, newest first.
  scheduleRuns: Item[];
  // A stream refused at open, and the sentence it was refused with.
  refusals: Record<string, string>;
  // Per stream, the highest revision heard of each item by its key, a
  // removed item's kept, so an older change cannot bring it back.
  revisions: Record<string, Record<string, number>>;
  // Per stream, the keys its picture has named since it began, while one
  // is being read (from an open or a `resync` until its `snapshot`).
  pictures: Record<string, string[] | null>;
  // Per stream, its delivery state when it is not live.
  delivery: Record<string, Delivery>;
  // What the windows over the canvas cover of it, as the shell tells it.
  covered: Rect[];
  // The posture the shell tells it, or null before it has.
  posture: Posture | null;
  // The person's preferences document, as the shell last told it.
  prefs: Item;
}

// A stream's state besides live (the delivery contract, `canvas.catalog`):
// its picture past its bound (`stale`, as of `at`), unreadable for now
// (`unavailable`, opened again at `at`), or no longer granted (`denied`).
export interface Delivery {
  state: "stale" | "unavailable" | "denied";
  at: string | null;
}

export const STREAMS = ["runs.changes", "schedules.changes", "schedule_runs.changes"];
// The field that names an item of each stream.
const KEYS: Record<string, string> = {
  "runs.changes": "execution_id",
  "schedules.changes": "schedule_id",
  "schedule_runs.changes": "occurrence_id",
};
// The sections, each a widget of the preferences document.
export const WIDGETS = ["attention", "runs", "apps", "schedules"];
// The controls the manifest declares, each picking a schedule's id.
export const PAUSE = "pause-schedule";
export const RESUME = "resume-schedule";
// Runs a failed run again, picking its execution id.
export const RETRY = "retry-run";
export const MAX_RUNS = 20;
export const MAX_SCHEDULE_RUNS = 10;

// Pauses before opening again a stream whose first open got no answer, or
// one the endpoint ended with no refusal, growing while opens fail.
export const RETRY_MS = [2_000, 5_000, 15_000, 60_000];

// The class cyfr.stream() rejects an open with when the endpoint gave no
// answer on it: it could not be reached, the connection broke or timed
// out, or it answered a server error. Opening it again later may succeed;
// any other rejection is a refusal, which opening it again meets again.
const UNANSWERED = "unavailable";

export const EMPTY: State = {
  apps: [],
  runs: [],
  schedules: new Map(),
  scheduleRuns: [],
  refusals: {},
  revisions: {},
  pictures: {},
  delivery: {},
  covered: [],
  posture: null,
  prefs: {},
};

// Opens the canvas's streams and hands `onChange` each new state. Calls
// `ready()` once, when every stream's first open has its answer: opened,
// refused, or unanswered and to be tried again. Answers the function that
// stops it all.
export function start(sdk: Sdk, onChange: (state: State) => void): () => void {
  let state = desktop(EMPTY, sdk.desktop);
  let stopped = false;
  const change = (next: State) => {
    if (stopped) return;
    state = next;
    onChange(state);
  };

  const offs = [
    sdk.on("installed", (list) => change(installed(state, list))),
    sdk.on("covered", (rects) => change(covered(state, rects))),
    sdk.on("posture", (posture) => change(postured(state, posture))),
    sdk.on("desktop", (value) => change(desktop(state, value))),
  ];

  const followers = STREAMS.map((name) =>
    follow(sdk, name, {
      change: (item, revision) => change(fold(state, name, item, revision)),
      resync: () => change(resynced(state, name)),
      snapshot: () => change(snapshotted(state, name)),
      delivery: (kind, at) => change(delivered(state, name, kind, at)),
      refused: (error) => change(refused(state, name, error)),
    })
  );

  Promise.allSettled(followers.map((follower) => follower.first)).then(() => {
    if (!stopped) sdk.ready();
  });

  return () => {
    stopped = true;
    offs.forEach((off) => off && off());
    followers.forEach((follower) => follower.stop());
  };
}

export function openApp(sdk: Sdk, app: InstalledApp): void {
  sdk.open(app.ref);
}

export function grantComponent(sdk: Sdk, ref: string): void {
  sdk.grant(ref);
}

// Pauses an active schedule or resumes a paused one, for the person's tap
// on its row. Answers the reason a refused press gives, or null: an
// accepted press shows in the stream's next event.
export async function pressSchedule(sdk: Sdk, row: ScheduleRow): Promise<string | null> {
  if (row.control === null) return null;
  const answer = await sdk.press(row.control, row.id);
  return answer.outcome === "refused" ? text(answer.reason) || "refused" : null;
}

// Shows or hides a section, for the person's tap: one tap, one write. A
// write that came second to another is not written again, since only the
// person's input carries a write: its answer holds the current document,
// which the page shows (through the `desktop` event) for the next tap.
export async function showWidget(sdk: Sdk, widget: string, on: boolean): Promise<Written> {
  return sdk.prefs({ widgets: { [widget]: { on } } });
}

// Whether the document shows the widget: every widget is shown until its
// entry says `on: false`.
export function isShown(document: unknown, widget: string): boolean {
  const widgets = isItem(document) && isItem(document.widgets) ? document.widgets : {};
  const entry = widgets[widget];
  return !(isItem(entry) && entry.on === false);
}

export function hidden(state: State): string[] {
  return WIDGETS.filter((widget) => !isShown(state.prefs, widget));
}

export function installed(state: State, list: unknown): State {
  const apps = Array.isArray(list) ? list.filter(isApp) : [];
  return {
    ...state,
    apps: apps.map((app) => ({
      ref: app.ref,
      name: app.name,
      icon: typeof app.icon === "string" && app.icon !== "" ? app.icon : null,
      open: app.open === true,
    })),
  };
}

export function covered(state: State, rects: unknown): State {
  return { ...state, covered: Array.isArray(rects) ? rects.filter(isRect) : [] };
}

export function postured(state: State, posture: unknown): State {
  return posture === "desk" || posture === "hand" ? { ...state, posture } : state;
}

export function desktop(state: State, value: unknown): State {
  const prefs = isItem(value) && isItem(value.prefs) ? value.prefs : null;
  return prefs && isItem(prefs.document) ? { ...state, prefs: prefs.document } : state;
}

// One change of `stream`, whole, at `revision`: kept only above the
// revision its item last had, an equal one being the same change heard
// again; a removal takes the item away and keeps its revision. A change
// that names no item is a notice, shown and never compared.
export function fold(state: State, stream: string, item: Item, revision: number | null = null): State {
  const key = keyOf(stream, item);
  let next = state;
  if (key !== null) {
    const held = state.revisions[stream]?.[key];
    if (revision !== null && held !== undefined && revision <= held) return state;
    const picture = state.pictures[stream];
    next = {
      ...state,
      revisions:
        revision === null ? state.revisions : { ...state.revisions, [stream]: { ...state.revisions[stream], [key]: revision } },
      pictures: picture ? { ...state.pictures, [stream]: [...picture, key] } : state.pictures,
    };
  }
  switch (stream) {
    case "runs.changes":
      return { ...next, runs: keepRun(next.runs, item) };
    case "schedules.changes":
      return { ...next, schedules: keepSchedule(next.schedules, item) };
    case "schedule_runs.changes":
      return { ...next, scheduleRuns: keepScheduleRun(next.scheduleRuns, item) };
    default:
      return next;
  }
}

// A fresh picture of `stream` begins (an open, or a `resync`): what it names
// until its `snapshot` is all that stream holds then, and its revisions,
// another subscription's, are compared with nothing held before.
export function resynced(state: State, stream: string): State {
  return {
    ...state,
    pictures: { ...state.pictures, [stream]: [] },
    revisions: { ...state.revisions, [stream]: {} },
  };
}

// The picture of `stream` is whole: every item it did not name is gone, and
// the stream is live again.
export function snapshotted(state: State, stream: string): State {
  const named = state.pictures[stream];
  const delivery = { ...state.delivery };
  delete delivery[stream];
  const next = { ...state, delivery, pictures: { ...state.pictures, [stream]: null } };
  if (!named) return next;
  const keep = new Set(named);
  const kept = (item: Item) => keep.has(text(item[KEYS[stream]]));
  switch (stream) {
    case "runs.changes":
      return { ...next, runs: next.runs.filter(kept) };
    case "schedules.changes":
      return { ...next, schedules: new Map([...next.schedules].filter(([id]) => keep.has(id))) };
    case "schedule_runs.changes":
      return { ...next, scheduleRuns: next.scheduleRuns.filter(kept) };
    default:
      return next;
  }
}

// `stream` turned stale, unavailable or denied. Denied ends it: what it
// held goes, and the section says it is no longer granted.
export function delivered(state: State, stream: string, kind: Delivery["state"], at: string | null): State {
  const next = { ...state, delivery: { ...state.delivery, [stream]: { state: kind, at } } };
  if (kind !== "denied") return next;
  const cleared = { ...next, revisions: { ...next.revisions, [stream]: {} }, pictures: { ...next.pictures, [stream]: null } };
  if (stream === "runs.changes") return { ...cleared, runs: [] };
  if (stream === "schedules.changes") return { ...cleared, schedules: new Map() };
  if (stream === "schedule_runs.changes") return { ...cleared, scheduleRuns: [] };
  return cleared;
}

// What a section reading `streams` says of their delivery, the worst of
// them, or null while every one is live.
export function deliveryNote(state: State, streams: string[]): { state: Delivery["state"]; text: string } | null {
  const rank = { stale: 1, unavailable: 2, denied: 3 };
  let worst: Delivery | null = null;
  for (const stream of streams) {
    const held = state.delivery[stream];
    if (held && (!worst || rank[held.state] > rank[worst.state])) worst = held;
  }
  if (!worst) return null;
  const time = clock(worst.at);
  if (worst.state === "denied") return { state: "denied", text: "No longer granted to this canvas." };
  if (worst.state === "unavailable") {
    return { state: "unavailable", text: time ? `Can't be read now · trying again at ${time}` : "Can't be read now" };
  }
  return { state: "stale", text: time ? `As of ${time}` : "Not fresh" };
}

function clock(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "" : date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

function keyOf(stream: string, item: Item): string | null {
  const key = KEYS[stream] ? item[KEYS[stream]] : undefined;
  return typeof key === "string" && key !== "" ? key : null;
}

export function refused(state: State, stream: string, error: unknown): State {
  const message = error instanceof Error ? error.message : "";
  const sentence = message || "This stream could not be opened.";
  return { ...state, refusals: { ...state.refusals, [stream]: sentence } };
}

// What App.tsx draws.

// The classes of a refusal a grant can fix, the person's grant missing or
// lapsed, and the causes a run's error reads as for them (Cyfr.Bus.Payload's
// table, which a drift test holds this list to). Every other cause is
// stated, and nothing is offered.
export const GRANTABLE = ["consent_required", "setup_required"];
export const GRANT_CAUSES = ["needs_setup"];

export function grantable(cls: string, cause: string): boolean {
  return GRANTABLE.includes(cls) || GRANT_CAUSES.includes(cause);
}

export interface Component {
  // The component's reference without its version, as a grant names it.
  ref: string;
  name: string;
  count: number;
}

export interface Cause {
  key: string;
  class: string;
  cause: string;
  // What the page shows for the cause: its class.
  shown: string;
  short: string;
  grantable: boolean;
  // How many of the held runs failed for it.
  count: number;
  components: Component[];
}

// The held runs that failed, grouped by their cause (the refusal's class
// and the cause it reads as), each with the components it hit, most often
// first; the causes most often first. A failure with no error is its own
// cause.
export function causes(state: State): Cause[] {
  const groups = new Map<string, Cause>();
  for (const run of state.runs) {
    if (run.kind !== "failed") continue;
    const error = isItem(run.error) ? run.error : {};
    const cls = text(error.class) || "internal";
    const why = text(error.cause);
    const key = `${cls}\u0000${why}`;
    const cause = groups.get(key) ?? {
      key,
      class: cls,
      cause: why,
      shown: cls,
      short: shortReason(why),
      grantable: grantable(cls, why),
      count: 0,
      components: [],
    };
    cause.count += 1;
    const ref = componentRef(text(run.reference));
    const component = cause.components.find((c) => c.ref === ref);
    if (component) component.count += 1;
    else cause.components.push({ ref, name: componentName(ref), count: 1 });
    groups.set(key, cause);
  }
  const ordered = [...groups.values()];
  for (const cause of ordered) cause.components.sort(byCount);
  return ordered.sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
}

// A few words for a failure, by its cause: the canvas's own, since the
// readable sentence each cause has in the stream's shape reaches the
// catalog and not the page.
const SHORT_REASONS = new Map([
  ["needs_setup", "Needs setup"],
  ["unavailable", "Unavailable"],
  ["timed_out", "Timed out"],
  ["cancelled", "Cancelled"],
  ["rate_limited", "Rate limited"],
  ["refused", "Refused"],
  ["bad_input", "Bad input"],
  ["not_found", "Not found"],
  ["waits_for_you", "Waits for you"],
]);

export function shortReason(cause: string): string {
  return SHORT_REASONS.get(cause) ?? "Failed";
}

// What the day says: the date, and one sentence about the held runs.
export function today(state: State, now: Date): { date: string; sentence: string } {
  const date = now.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" });
  const settled = state.runs.filter((run) => run.kind !== "started");
  const failed = settled.filter((run) => run.kind === "failed").length;
  if (settled.length === 0) return { date, sentence: "No runs yet." };
  const last = settled.length === 1 ? "your last run" : `your last ${settled.length} runs`;
  if (failed === 0) {
    return { date, sentence: settled.length === 1 ? "Your last run finished." : `None of ${last} failed.` };
  }
  let sentence =
    settled.length === 1
      ? "Your last run failed."
      : failed === settled.length
        ? `All of ${last} failed.`
        : `${failed} of ${last} failed.`;
  const grantable = causes(state).filter((cause) => cause.grantable);
  const fixed = grantable.reduce((sum, cause) => sum + cause.count, 0);
  const grants = new Set(grantable.flatMap((cause) => cause.components.map((c) => c.ref))).size;
  if (fixed > 0) {
    const them = fixed === failed ? (failed === 1 ? "it" : "all of them") : `${fixed} of them`;
    sentence += ` ${capital(count(grants))} grant${grants === 1 ? " fixes" : "s fix"} ${them}.`;
  }
  return { date, sentence };
}

export type Status = "ok" | "bad" | "warn" | "run";

export function status(run: Item): Status {
  if (run.kind === "completed") return "ok";
  if (run.kind === "failed") return "bad";
  if (run.kind === "cancelled") return "warn";
  return "run";
}

// The held runs, newest first, as the strip shows them.
export function strip(state: State): Status[] {
  return state.runs.map(status);
}

export interface RunRow {
  id: string;
  status: Status;
  name: string;
  detail: string;
  reason: string;
  duration: string;
  // Whether Retry is offered: a failed run that no other run started.
  retry: boolean;
}

// The first `limit` runs as rows, newest first, and how many more there are.
export function recentRows(state: State, limit: number): { rows: RunRow[]; more: number } {
  const rows = state.runs.slice(0, limit).map((run) => {
    const reference = text(run.reference);
    const error = isItem(run.error) ? run.error : null;
    return {
      id: text(run.execution_id),
      status: status(run),
      name: componentName(componentRef(reference)) || reference,
      detail: referenceDetail(reference),
      reason:
        run.kind === "failed"
          ? shortReason(text(error?.cause))
          : run.kind === "started"
            ? "Running"
            : run.kind === "cancelled"
              ? "Cancelled"
              : "Finished",
      duration: duration(run.duration_ms),
      retry: run.kind === "failed" && run.parent_execution_id == null && text(run.execution_id) !== "",
    };
  });
  return { rows, more: Math.max(0, state.runs.length - limit) };
}

// What Retry's answer says, in the canvas's words, by the refusal's class.
const RETRY_REFUSED = new Map([
  ["conflict", "This run cannot run again: only a run a schedule or a feed started, known to have failed, does"],
  ["invalid_argument", "This run is no longer among the latest runs"],
  ["not_found", "This run is gone"],
  ["forbidden", "This run is not yours to run again"],
  ["unavailable", "CYFR cannot run it now: try again shortly"],
  ["rate_limited", "CYFR cannot run it now: try again shortly"],
  ["timeout", "CYFR cannot run it now: try again shortly"],
  ["uncertain", "No answer came: look at your runs before trying again"],
]);

// Runs a failed run again, for the person's tap on its row: one tap, one
// press. Answers what the row says: the new run's outcome shows as it
// arrives on runs.changes.
export async function retryRun(sdk: Sdk, row: RunRow): Promise<string> {
  const answer = await sdk.press(RETRY, row.id);
  if (answer.outcome === "accepted") return "Running again";
  if (answer.outcome === "cancelled") return answer.reason === "too_soon" ? "Tap again in a moment" : "Nothing ran";
  return RETRY_REFUSED.get(text(answer.reason)) ?? "It could not run again";
}

export interface ScheduleRow {
  id: string;
  name: string;
  paused: boolean;
  // The control its row offers: Pause while it is active, Resume while it
  // is paused, and neither in any other status.
  control: typeof PAUSE | typeof RESUME | null;
  next: string;
  last: string;
  runs: string;
  errors: string;
  // The outcome of its last run the canvas heard of, or null.
  lastOutcome: Status | null;
}

export function scheduleRows(state: State, now: Date): ScheduleRow[] {
  return byNextFire(state).map((schedule) => {
    const id = text(schedule.schedule_id);
    const lastRun = state.scheduleRuns.find((run) => run.schedule_id === id);
    return {
      id,
      name: text(schedule.name) || text(schedule.reference),
      paused: schedule.status === "paused",
      control: schedule.status === "active" ? PAUSE : schedule.status === "paused" ? RESUME : null,
      next: schedule.status === "paused" ? "paused" : relative(schedule.next_run_at, now, "not planned"),
      last: relative(schedule.last_run_at, now, "never"),
      runs: text(schedule.run_count) || "0",
      errors: text(schedule.error_count) || "0",
      lastOutcome: lastRun ? (lastRun.kind === "failed" ? "bad" : "ok") : null,
    };
  });
}

export interface Day {
  label: string;
  day: number;
  today: boolean;
  // The schedules whose next run falls on this day, by name.
  next: string[];
}

// The next seven days from `now`'s, each with the live schedules whose
// next run (the stream's `next_run_at`, as the server plans it) falls on
// it. The canvas reads no cron expression: what fires after the next run
// is the server's to say.
export function week(state: State, now: Date): Day[] {
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const days: Day[] = Array.from({ length: 7 }, (_, i) => {
    const day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
    return {
      label: day.toLocaleDateString(undefined, { weekday: "short" }),
      day: day.getDate(),
      today: i === 0,
      next: [],
    };
  });
  for (const schedule of byNextFire(state)) {
    if (schedule.status === "paused" || typeof schedule.next_run_at !== "string") continue;
    const t = Date.parse(schedule.next_run_at);
    if (Number.isNaN(t)) continue;
    const at = new Date(t);
    const index = Math.round(
      (new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime() - start.getTime()) / DAY_MS
    );
    if (index >= 0 && index < 7) days[index].next.push(text(schedule.name) || text(schedule.reference));
  }
  return days;
}

// When `value` (a time) is from `now`, in words: "in 5 minutes", "3 hours
// ago", "yesterday"; `absent` for no time.
export function relative(value: unknown, now: Date, absent: string): string {
  const t = typeof value === "string" ? Date.parse(value) : NaN;
  if (Number.isNaN(t)) return absent;
  const seconds = Math.round((t - now.getTime()) / 1000);
  const words = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const size = Math.abs(seconds);
  if (size < 45) return seconds < 0 ? "just now" : "in a moment";
  if (size < 45 * 60) return words.format(Math.round(seconds / 60), "minute");
  if (size < 22 * 3600) return words.format(Math.round(seconds / 3600), "hour");
  if (size < 26 * 86400) return words.format(Math.round(seconds / 86400), "day");
  return new Date(t).toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

// Where "Needs attention" goes in the desk's columns (`{x, width}` in the
// page's pixels, in their order) when it stands from `top` for `height`
// pixels: its own column, the first, while no window covers it there;
// otherwise the first column it would stand uncovered in; otherwise the
// one where the least of it is covered.
export function attentionColumn(
  columns: { x: number; width: number }[],
  rects: Rect[],
  top: number,
  height: number
): number {
  if (columns.length === 0) return 0;
  const hidden = columns.map(({ x, width }) =>
    rects.reduce((sum, r) => sum + overlap({ x, y: top, width, height }, r), 0)
  );
  const free = hidden.findIndex((area) => area === 0);
  if (free !== -1) return free;
  return hidden.indexOf(Math.min(...hidden));
}

function overlap(a: Rect, b: Rect): number {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

// A monogram's colour for an app with no emoji, the same for the same name.
export const MONOGRAM_HUES = [239, 199, 160, 32, 330, 270];

export function monogram(name: string): { letter: string; hue: number } {
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + (ch.codePointAt(0) ?? 0)) >>> 0;
  return {
    letter: (Array.from(name)[0] ?? "?").toUpperCase(),
    hue: MONOGRAM_HUES[hash % MONOGRAM_HUES.length],
  };
}

// "catalyst:local.openai:1.4.1" without its version.
export function componentRef(reference: string): string {
  const parts = reference.split(":");
  return parts.length === 3 ? `${parts[0]}:${parts[1]}` : reference;
}

// "catalyst:local.openai" as a person reads it: "openai".
export function componentName(ref: string): string {
  const named = ref.split(":")[1] ?? "";
  return named.includes(".") ? named.slice(named.indexOf(".") + 1) : named;
}

// "catalyst:local.openai:1.4.1" as its row's detail: "catalyst · 1.4.1".
function referenceDetail(reference: string): string {
  const [type, , version] = reference.split(":");
  return [type, version].filter(Boolean).join(" · ");
}

const NUMBERS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];

function count(n: number): string {
  return NUMBERS[n] ?? String(n);
}

function capital(word: string): string {
  return word.charAt(0).toUpperCase() + word.slice(1);
}

function byCount(a: Component, b: Component): number {
  return b.count - a.count || a.name.localeCompare(b.name);
}

const DAY_MS = 86_400_000;

// A schedule with no next fire sorts last.
export function byNextFire(state: State): Item[] {
  const at = (schedule: Item) => {
    const t = typeof schedule.next_run_at === "string" ? Date.parse(schedule.next_run_at) : NaN;
    return Number.isNaN(t) ? Number.MAX_SAFE_INTEGER : t;
  };
  return [...state.schedules.values()].map((held) => held.schedule).sort((a, b) => at(a) - at(b));
}


// Every value is drawn as text: a string as itself, a finite number as its
// digits, and anything else as nothing.
export function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}


export function duration(ms: unknown): string {
  if (typeof ms !== "number" || !Number.isFinite(ms)) return "";
  return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;
}


// One entry per run, the latest change first. A start published while the
// stream opened can arrive after the refresh already showed that run
// finished, so a finished run keeps its outcome.
function keepRun(runs: Item[], run: Item): Item[] {
  const id = run.execution_id;
  if (typeof id !== "string") return runs;
  const before = runs.find((r) => r.execution_id === id);
  if (before && before.kind !== "started" && run.kind === "started") return runs;
  return [run, ...runs.filter((r) => r.execution_id !== id)].slice(0, MAX_RUNS);
}

function keepSchedule(schedules: State["schedules"], schedule: Item): State["schedules"] {
  const id = schedule.schedule_id;
  if (typeof id !== "string") return schedules;
  const next = new Map(schedules);
  if (schedule.kind === "removed") next.delete(id);
  else next.set(id, { schedule });
  return next;
}

function keepScheduleRun(runs: Item[], run: Item): Item[] {
  const id = run.occurrence_id;
  const rest = typeof id === "string" ? runs.filter((r) => r.occurrence_id !== id) : runs;
  return [run, ...rest].slice(0, MAX_SCHEDULE_RUNS);
}

function isApp(app: unknown): app is Item & { ref: string; name: string } {
  const { ref, name } = (app ?? {}) as Partial<InstalledApp>;
  return typeof ref === "string" && typeof name === "string";
}

function isRect(rect: unknown): rect is Rect {
  if (typeof rect !== "object" || rect === null) return false;
  const r = rect as Record<string, unknown>;
  return ["x", "y", "width", "height"].every((k) => typeof r[k] === "number" && Number.isFinite(r[k]));
}

// Whether a rejected open got no answer, and so may open later.
function unanswered(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as Item).code === UNANSWERED;
}

// What a stream's follower tells: each change with its revision, a fresh
// picture beginning and being whole, its delivery state, and a refusal.
interface Follower {
  change(item: Item, revision: number | null): void;
  resync(): void;
  snapshot(): void;
  delivery(kind: Delivery["state"], at: string | null): void;
  refused(error: unknown): void;
}

// Keeps one declared stream open by the delivery contract. The SDK opens
// an opened stream again by itself, after a lost connection or while the
// canvas was hidden, announcing its fresh picture with `resync`; the page
// opens one again only when its first open got no answer, or when the
// endpoint ended it with no refusal (its handle `ended`, as at its grant's
// bound). A denied stream ends and is never opened again by the page, and
// an open the endpoint refused is final: `refused` hears the refusal.
// Every open begins a fresh picture. `first` resolves when the first open
// has its answer.
function follow(sdk: Sdk, name: string, on: Follower): { first: Promise<void>; stop(): void } {
  let stopped = false;
  let opens = 0;
  let current: StreamHandle | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;

  async function open(): Promise<void> {
    const n = ++opens;
    on.resync();
    const stream = await sdk.stream(name, null, (event) => {
      if (stopped || n !== opens) return;
      const { event: kind, data } = event;
      // A change of the stream itself; a delivery event's data (`unavailable`'s
      // retry time, `denied`'s refusal) is no item of it.
      if (kind === name) {
        if (isItem(data)) on.change(data, revisionOf(event));
      } else if (kind === "resync") on.resync();
      else if (kind === "snapshot") on.snapshot();
      else if (kind === "stale") on.delivery("stale", text(event.at) || null);
      else if (kind === "unavailable") on.delivery("unavailable", isItem(data) ? text(data.retry_at) || null : null);
      else if (kind === "denied") on.delivery("denied", null);
    });
    if (stopped) {
      stream.close();
      return;
    }
    current = stream;
    const ended = () => {
      if (current !== stream) return;
      current = null;
      if (stream.state === "ended") retry(0);
    };
    stream.closed.then(ended, ended);
  }

  // An open that failed at `attempt`: one with no answer is tried again
  // after the pause; a refusal is final.
  function failed(error: unknown, attempt: number) {
    if (stopped) return;
    if (unanswered(error)) retry(attempt);
    else on.refused(error);
  }

  function retry(attempt: number) {
    if (stopped) return;
    timer = setTimeout(() => {
      open().catch((error: unknown) => failed(error, Math.min(attempt + 1, RETRY_MS.length - 1)));
    }, RETRY_MS[attempt]);
  }

  return {
    first: open().catch((error: unknown) => failed(error, 0)),
    stop() {
      stopped = true;
      clearTimeout(timer);
      current?.close();
    },
  };
}

// A change's revision, as the SDK hands it or as its data carries it.
function revisionOf(event: StreamEvent): number | null {
  if (Number.isInteger(event.revision)) return event.revision as number;
  const data = event.data;
  return isItem(data) && Number.isInteger(data.revision) ? (data.revision as number) : null;
}

function isItem(data: unknown): data is Item {
  return typeof data === "object" && data !== null && !Array.isArray(data);
}

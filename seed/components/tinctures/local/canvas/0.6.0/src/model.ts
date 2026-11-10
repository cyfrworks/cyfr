// Everything the canvas does apart from drawing: the SDK calls, the streams
// it keeps open, and how each stream's events fold into the state App.tsx
// draws. Its TypeScript is types only, so the canvas's tests run this file
// as it is.

// The part of window.cyfr this canvas uses.
export interface Sdk {
  // Answers the function that stops the handler hearing more.
  on(event: "installed" | "covered" | "posture" | "desktop", handler: (value: unknown) => void): (() => void) | void;
  stream(
    name: string,
    subject: string | null,
    onEvent: (event: { id: number | null; event: string; data: unknown }) => void
  ): Promise<{ close(): void; closed: Promise<void> }>;
  open(ref: string): void;
  grant(ref: string): void;
  // A control the canvas declares, with the value its pick takes.
  press(control: string, value: string | null): Promise<Pressed>;
  // Each widget the document names replaces that widget's whole entry.
  prefs(document: { widgets: Record<string, { on: boolean }> }): Promise<Written>;
  // `prefs` is the person's preferences document for this canvas, null
  // until the canvas's open arrives.
  readonly desktop: { prefs: { document: unknown; revision: number } } | null;
  ready(): void;
}

export interface Pressed {
  outcome: "accepted" | "refused" | "cancelled";
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
  // By schedule id, with the number of the open that last delivered each.
  schedules: Map<string, { schedule: Item; open: number }>;
  // The last schedule runs, newest first.
  scheduleRuns: Item[];
  // A stream refused at open, and the sentence it was refused with.
  refusals: Record<string, string>;
  // What the windows over the canvas cover of it, as the shell tells it.
  covered: Rect[];
  // The posture the shell tells it, or null before it has.
  posture: Posture | null;
  // The person's preferences document, as the shell last told it.
  prefs: Item;
}

export const STREAMS = ["runs.changes", "schedules.changes", "schedule_runs.changes"];
// The sections, each a widget of the preferences document.
export const WIDGETS = ["attention", "runs", "apps", "schedules"];
// The controls the manifest declares, each picking a schedule's id.
export const PAUSE = "pause-schedule";
export const RESUME = "resume-schedule";
export const MAX_RUNS = 20;
export const MAX_SCHEDULE_RUNS = 10;

// Pauses before opening an ended stream again, growing while opens fail.
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
    follow(
      sdk,
      name,
      (item, open) => change(fold(state, name, item, open)),
      (open) => change(opened(state, name, open)),
      (error) => change(refused(state, name, error))
    )
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

export function fold(state: State, stream: string, item: Item, open: number): State {
  switch (stream) {
    case "runs.changes":
      return { ...state, runs: keepRun(state.runs, item) };
    case "schedules.changes":
      return { ...state, schedules: keepSchedule(state.schedules, item, open) };
    case "schedule_runs.changes":
      return { ...state, scheduleRuns: keepScheduleRun(state.scheduleRuns, item) };
    default:
      return state;
  }
}

// A reopened stream's refresh holds every schedule there is, so a schedule
// an earlier open delivered and this one did not was removed in between.
export function opened(state: State, stream: string, open: number): State {
  if (stream !== "schedules.changes") return state;
  const schedules = new Map([...state.schedules].filter(([, held]) => held.open >= open));
  return { ...state, schedules };
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
    };
  });
  return { rows, more: Math.max(0, state.runs.length - limit) };
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

function keepSchedule(schedules: State["schedules"], schedule: Item, open: number): State["schedules"] {
  const id = schedule.schedule_id;
  if (typeof id !== "string") return schedules;
  const next = new Map(schedules);
  if (schedule.kind === "removed") next.delete(id);
  else next.set(id, { schedule, open });
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

// Keeps one declared stream open. Every stream ends in time (its grant has
// a deadline, and a connection can break), so a stream that ends is opened
// again after a pause, and starts again with its refresh, the current
// state. Until the stream has opened once, an open the endpoint refused is
// final: `onRefused` hears the refusal and nothing is retried; an open it
// gave no answer on is tried again on the same pauses. Once it has opened,
// every failed reopen is tried again. `first` resolves when the first open
// has its answer. Each item comes with the number of the open that
// delivered it, and `onOpen` hears each open's number once that open
// succeeds.
function follow(
  sdk: Sdk,
  name: string,
  onItem: (item: Item, open: number) => void,
  onOpen: (open: number) => void,
  onRefused: (error: unknown) => void
): { first: Promise<void>; stop(): void } {
  let stopped = false;
  let opens = 0;
  let everOpened = false;
  let current: { close(): void } | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;

  async function open(): Promise<void> {
    const n = ++opens;
    const stream = await sdk.stream(name, null, ({ data }) => {
      if (!stopped && isItem(data)) onItem(data, n);
    });
    if (stopped) {
      stream.close();
      return;
    }
    everOpened = true;
    current = stream;
    onOpen(n);
    stream.closed
      .catch(() => {})
      .then(() => {
        current = null;
        retry(0);
      });
  }

  // An open that failed at `attempt`: a refusal before the stream ever
  // opened ends it; anything else is tried again after the pause.
  function failed(error: unknown, attempt: number) {
    if (stopped) return;
    if (!everOpened && !unanswered(error)) onRefused(error);
    else retry(attempt);
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

function isItem(data: unknown): data is Item {
  return typeof data === "object" && data !== null && !Array.isArray(data);
}

// Everything the canvas does apart from drawing: the SDK calls, the streams
// it keeps open, and how each stream's events fold into the state App.tsx
// draws. Its TypeScript is types only, so the canvas's tests run this file
// as it is.

// The part of window.cyfr this canvas uses.
export interface Sdk {
  // Answers the function that stops the handler hearing more.
  on(event: "installed", handler: (apps: unknown) => void): (() => void) | void;
  stream(
    name: string,
    subject: string | null,
    onEvent: (event: { id: number | null; event: string; data: unknown }) => void
  ): Promise<{ close(): void; closed: Promise<void> }>;
  open(ref: string): void;
  ready(): void;
}

export interface InstalledApp {
  ref: string;
  name: string;
}

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
}

export const STREAMS = ["runs.changes", "schedules.changes", "schedule_runs.changes"];
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
};

// Opens the canvas's streams and hands `onChange` each new state. Calls
// `ready()` once, when every stream's first open has its answer: opened,
// refused, or unanswered and to be tried again. Answers the function that
// stops it all.
export function start(sdk: Sdk, onChange: (state: State) => void): () => void {
  let state = EMPTY;
  let stopped = false;
  const change = (next: State) => {
    if (stopped) return;
    state = next;
    onChange(state);
  };

  const off = sdk.on("installed", (list) => change(installed(state, list)));

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
    if (off) off();
    followers.forEach((follower) => follower.stop());
  };
}

export function openApp(sdk: Sdk, app: InstalledApp): void {
  sdk.open(app.ref);
}

export function installed(state: State, list: unknown): State {
  return { ...state, apps: Array.isArray(list) ? list.filter(isApp) : [] };
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

// What App.tsx draws, in the order it draws it.

export function failedFirst(state: State): Item[] {
  return [
    ...state.runs.filter((run) => run.kind === "failed"),
    ...state.runs.filter((run) => run.kind !== "failed"),
  ];
}

// A schedule with no next fire sorts last.
export function byNextFire(state: State): Item[] {
  const at = (schedule: Item) => {
    const t = typeof schedule.next_run_at === "string" ? Date.parse(schedule.next_run_at) : NaN;
    return Number.isNaN(t) ? Number.MAX_SAFE_INTEGER : t;
  };
  return [...state.schedules.values()].map((held) => held.schedule).sort((a, b) => at(a) - at(b));
}

export function scheduleName(state: State, id: unknown): string {
  const held = typeof id === "string" ? state.schedules.get(id) : undefined;
  return text(held?.schedule.name) || text(id);
}

// Every value is drawn as text: a string as itself, a finite number as its
// digits, and anything else as nothing.
export function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export function errorMessage(error: unknown): string {
  return typeof error === "object" && error !== null ? text((error as Item).message) : "";
}

export function duration(ms: unknown): string {
  if (typeof ms !== "number" || !Number.isFinite(ms)) return "";
  return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;
}

export function when(value: unknown, absent: string): string {
  const t = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isNaN(t) ? absent : new Date(t).toLocaleString();
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

function isApp(app: unknown): app is InstalledApp {
  const { ref, name } = (app ?? {}) as Partial<InstalledApp>;
  return typeof ref === "string" && typeof name === "string";
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

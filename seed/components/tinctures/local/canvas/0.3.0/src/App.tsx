import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import {
  EMPTY,
  attentionColumn,
  causes,
  grantComponent,
  monogram,
  openApp,
  recentRows,
  scheduleRows,
  start,
  strip,
  today,
  week,
  type Cause,
  type InstalledApp,
  type State,
  type Status,
} from "./model";

// How many runs the rows show before "N more".
const ROWS = 8;
// The narrowest page the desk's two columns fit, below which it stacks
// them as the hand does.
const TWO_COLUMNS_PX = 860;

export default function App() {
  const [state, setState] = useState(EMPTY);
  const [now, setNow] = useState(() => new Date());
  const [width, setWidth] = useState(() => window.innerWidth);

  useEffect(() => start(cyfr, setState), []);

  // Relative times move on, and the page follows its own width.
  useEffect(() => {
    const tick = setInterval(() => setNow(new Date()), 30_000);
    const resize = () => setWidth(window.innerWidth);
    window.addEventListener("resize", resize);
    return () => {
      clearInterval(tick);
      window.removeEventListener("resize", resize);
    };
  }, []);

  const stacked = state.posture === "hand" || width < TWO_COLUMNS_PX;
  const day = today(state, now);
  const attention = <Attention state={state} />;

  return (
    <main className={stacked ? "stacked" : "desk"}>
      <header className="today">
        <h1>{day.date}</h1>
        <p>{day.sentence}</p>
      </header>
      {stacked ? (
        <div className="column">
          {attention}
          <Runs state={state} />
          <Apps state={state} />
          <Schedules state={state} now={now} />
        </div>
      ) : (
        <Desk state={state} attention={attention} now={now} />
      )}
    </main>
  );
}

// The desk's two columns. "Needs attention" stands at the top of the
// first; when a window covers it there, it moves to the top of the first
// column where nothing covers it, and every other section stays where it
// is.
function Desk({ state, attention, now }: { state: State; attention: ReactNode; now: Date }) {
  const columns = [useRef<HTMLDivElement>(null), useRef<HTMLDivElement>(null)];
  const block = useRef<HTMLDivElement>(null);
  const [slot, setSlot] = useState(0);

  useLayoutEffect(() => {
    const boxes = columns.map((ref) => ref.current?.getBoundingClientRect());
    const own = block.current?.getBoundingClientRect();
    if (!boxes[0] || !boxes[1] || !own) return;
    const next = attentionColumn(
      boxes.map((box) => ({ x: box!.x, width: box!.width })),
      state.covered,
      boxes[0].y,
      own.height
    );
    if (next !== slot) setSlot(next);
    // The covered rects and the page's own content decide; the slot it
    // stands in now is where it was measured.
  }, [state.covered, state.runs, state.apps, state.schedules]);

  const placed = <div ref={block}>{attention}</div>;

  return (
    <div className="columns">
      <div className="column" ref={columns[0]}>
        {slot === 0 && placed}
        <Runs state={state} />
      </div>
      <div className="column" ref={columns[1]}>
        {slot === 1 && placed}
        <Apps state={state} />
        <Schedules state={state} now={now} />
      </div>
    </div>
  );
}

function Attention({ state }: { state: State }) {
  const list = causes(state);
  if (list.length === 0) return null;
  return (
    <Section title="Needs attention" count={String(list.length)} refusal={state.refusals["runs.changes"]}>
      {list.map((cause) => (
        <CauseRow key={cause.key} cause={cause} />
      ))}
    </Section>
  );
}

function CauseRow({ cause }: { cause: Cause }) {
  return (
    <div className="issue">
      <Dot status={cause.grantable ? "bad" : "warn"} />
      <div className="body">
        <div className="title">
          {cause.count} {cause.count === 1 ? "run" : "runs"} failed
          {cause.short !== "Failed" && <span className="muted"> · {cause.short.toLowerCase()}</span>}
        </div>
        <p className="why">{cause.message}</p>
        <div className="chips">
          {cause.components.map((component) =>
            cause.grantable ? (
              <button
                key={component.ref}
                className="chip action"
                title={`Ask CYFR to grant ${component.name}`}
                onClick={() => grantComponent(cyfr, component.ref)}
              >
                <b>Grant {component.name}</b>
                {component.count > 1 && <span className="muted"> ×{component.count}</span>}
              </button>
            ) : (
              <span key={component.ref} className="chip">
                <b>{component.name}</b>
                {component.count > 1 && <span className="muted"> ×{component.count}</span>}
              </span>
            )
          )}
        </div>
      </div>
    </div>
  );
}

function Runs({ state }: { state: State }) {
  const { rows, more } = recentRows(state, ROWS);
  const squares = strip(state);
  return (
    <Section
      title="Recent runs"
      count={state.runs.length > 0 ? `last ${state.runs.length}` : undefined}
      refusal={state.refusals["runs.changes"]}
    >
      {rows.length === 0 ? (
        <p className="empty">No runs yet. A run of any component shows here as it happens.</p>
      ) : (
        <>
          <div className="strip" aria-label="Your last runs, newest first">
            {squares.map((status, i) => (
              <i key={i} className={status} title={label(status)} />
            ))}
          </div>
          <div className="strip-ends">
            <span>newest</span>
            <span>oldest</span>
          </div>
          {rows.map((row) => (
            <div key={row.id} className="run">
              <Dot status={row.status} />
              <span className="name">
                <b>{row.name}</b> <span className="muted">{row.detail}</span>
              </span>
              <span className={`reason ${row.status}`}>{row.reason}</span>
              <span className="muted tabular">{row.duration}</span>
            </div>
          ))}
          {more > 0 && <p className="more">{more} more</p>}
        </>
      )}
    </Section>
  );
}

function Apps({ state }: { state: State }) {
  return (
    <Section title="Apps" count={state.apps.length > 0 ? String(state.apps.length) : undefined}>
      {state.apps.length === 0 ? (
        <p className="empty">No apps are installed yet. Ask AQUA to make you one.</p>
      ) : (
        <div className="apps">
          {state.apps.map((app) => (
            <AppTile key={app.ref} app={app} />
          ))}
        </div>
      )}
    </Section>
  );
}

function AppTile({ app }: { app: InstalledApp }) {
  const mark = monogram(app.name);
  return (
    <button
      className={app.open ? "app open" : "app"}
      title={app.open ? `${app.name} is open` : `Open ${app.name}`}
      onClick={() => openApp(cyfr, app)}
    >
      {app.icon ? (
        <span className="icon">{app.icon}</span>
      ) : (
        <span className="icon monogram" style={{ ["--hue" as string]: String(mark.hue) }}>
          {mark.letter}
        </span>
      )}
      <span className="label">{app.name}</span>
    </button>
  );
}

function Schedules({ state, now }: { state: State; now: Date }) {
  const rows = scheduleRows(state, now);
  const days = week(state, now);
  return (
    <Section
      title="Schedules"
      count={rows.length > 0 ? String(rows.length) : "none yet"}
      refusal={state.refusals["schedules.changes"]}
    >
      {rows.length === 0 ? (
        <p className="empty">
          Nothing is scheduled. Ask AQUA to run something for you, say every morning at seven.
        </p>
      ) : (
        rows.map((row) => (
          <div key={row.id} className="schedule">
            <Dot status={row.paused ? "warn" : row.lastOutcome === "bad" ? "bad" : "ok"} />
            <div className="body">
              <div className="title">{row.name}</div>
              <div className="muted">
                next {row.next} · last {row.last} · {row.runs} runs, {row.errors} errors
              </div>
            </div>
          </div>
        ))
      )}
      <div className="week" aria-label="Runs planned this week">
        {days.map((day) => (
          <div key={day.label + day.day} className={day.today ? "day today" : "day"}>
            <span>{day.label}</span>
            <b>{day.day}</b>
            <span className={day.fires > 0 ? "fires" : "fires none"}>{day.fires > 0 ? day.fires : "·"}</span>
          </div>
        ))}
      </div>
    </Section>
  );
}

// A section's heading, then its content, or the sentence its stream was
// refused with in place of the content.
function Section({
  title,
  count,
  refusal,
  children,
}: {
  title: string;
  count?: string;
  refusal?: string;
  children: ReactNode;
}) {
  return (
    <section className="card">
      <h2>
        {title} {count && <span className="count">{count}</span>}
      </h2>
      {refusal ? <p className="refusal">{refusal}</p> : children}
    </section>
  );
}

function Dot({ status }: { status: Status }) {
  return <span className={`dot ${status}`} aria-label={label(status)} />;
}

function label(status: Status): string {
  return { ok: "finished", bad: "failed", warn: "stopped", run: "running" }[status];
}

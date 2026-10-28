import { useEffect, useState, type ReactNode } from "react";
import {
  EMPTY,
  byNextFire,
  duration,
  errorMessage,
  failedFirst,
  openApp,
  scheduleName,
  start,
  text,
  when,
} from "./model";

export default function App() {
  const [state, setState] = useState(EMPTY);

  useEffect(() => start(cyfr, setState), []);

  const runs = failedFirst(state);
  const schedules = byNextFire(state);

  return (
    <main>
      <Section title="Apps">
        {state.apps.length === 0 ? (
          <p className="empty">No apps are installed yet.</p>
        ) : (
          <div className="tiles">
            {state.apps.map((app) => (
              <button key={app.ref} className="tile" onClick={() => openApp(cyfr, app)}>
                <span className="mark">{Array.from(app.name)[0]?.toUpperCase()}</span>
                <span className="name">{app.name}</span>
              </button>
            ))}
          </div>
        )}
      </Section>

      <Section title="Recent runs" refusal={state.refusals["runs.changes"]}>
        {runs.length === 0 ? (
          <p className="empty">No runs yet.</p>
        ) : (
          <ul className="rows">
            {runs.map((run) => (
              <li key={text(run.execution_id)} className={run.kind === "failed" ? "row failed" : "row"}>
                <span className="title">{text(run.reference)}</span>
                <span className="kind">{text(run.kind)}</span>
                <span className="detail">{duration(run.duration_ms)}</span>
                {errorMessage(run.error) && <p className="error">{errorMessage(run.error)}</p>}
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Schedules" refusal={state.refusals["schedules.changes"]}>
        {schedules.length === 0 ? (
          <p className="empty">No schedules yet.</p>
        ) : (
          <ul className="rows">
            {schedules.map((schedule) => (
              <li key={text(schedule.schedule_id)} className="row">
                <span className="title">{text(schedule.name) || text(schedule.reference)}</span>
                <span className="kind">{text(schedule.status)}</span>
                <span className="detail">next {when(schedule.next_run_at, "not planned")}</span>
                <p className="more">
                  {text(schedule.cron_expression)} · last {when(schedule.last_run_at, "never")} ·{" "}
                  {text(schedule.run_count) || "0"} runs, {text(schedule.error_count) || "0"} errors
                </p>
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Schedule runs" refusal={state.refusals["schedule_runs.changes"]}>
        {state.scheduleRuns.length === 0 ? (
          <p className="empty">No schedule has run yet.</p>
        ) : (
          <ul className="rows">
            {state.scheduleRuns.map((run, i) => (
              <li key={text(run.occurrence_id) || i} className={run.kind === "failed" ? "row failed" : "row"}>
                <span className="title">{scheduleName(state, run.schedule_id)}</span>
                <span className="kind">{text(run.kind)}</span>
                <span className="detail">{when(run.scheduled_for, "")}</span>
                {text(run.reason) && <p className="more">{text(run.reason)}</p>}
              </li>
            ))}
          </ul>
        )}
      </Section>
    </main>
  );
}

// A section's heading, then its content, or the sentence its stream was
// refused with in place of the content.
function Section({ title, refusal, children }: { title: string; refusal?: string; children: ReactNode }) {
  return (
    <section>
      <h2>{title}</h2>
      {refusal ? <p className="refusal">{refusal}</p> : children}
    </section>
  );
}

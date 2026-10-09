// The shipped canvas: a launcher for each app the person installed, and
// their recent runs. It runs in the toolkit's module worker and draws only
// through the `canvas` it is handed: it reads `installed` from the shell
// and the stream `runs.changes`, its one declared stream, and answers
// element trees. A launcher is a control bound to an `open` effect, whose
// label the toolkit draws from the installed tincture's name.
//
// `runs.changes` answers the athanor's newest runs as its refresh, oldest
// first, then each change live; a change racing the refresh can arrive
// twice, so a change is taken once per run and kind. Each run is shown as
// the last change it made, the newest run first.

const MAX_RUNS = 20
const MAX_SEEN = 512
const MAX_CELL = 1024

export default function canvas(api) {
  let installed = []
  let posture = "desk"
  let runs = []
  let seen = new Set()

  const draw = () => api.render(tree(installed, runs, posture))

  api.on("installed", (tinctures) => {
    installed = Array.isArray(tinctures) ? tinctures.filter(launchable) : []
    draw()
  })

  api.on("posture", (value) => {
    posture = value === "hand" ? "hand" : "desk"
    draw()
  })

  api.stream("runs.changes", null, (event) => {
    const change = event && event.data
    if (!readable(change)) return

    const key = change.execution_id + "\n" + change.kind
    if (seen.has(key)) return
    seen.add(key)

    runs = [change, ...runs.filter((run) => run.execution_id !== change.execution_id)].slice(0, MAX_RUNS)
    if (seen.size > MAX_SEEN) seen = new Set(runs.map((run) => run.execution_id + "\n" + run.kind))
    draw()
  }).catch(() => {
    // A stream that cannot be opened leaves the launchers drawn.
  })

  draw()
}

const launchable = (tincture) =>
  tincture !== null && typeof tincture === "object" && typeof tincture.ref === "string" && typeof tincture.name === "string"

const readable = (change) =>
  change !== null &&
  typeof change === "object" &&
  typeof change.execution_id === "string" &&
  typeof change.kind === "string"

function tree(installed, runs, posture) {
  return {
    type: "stack",
    direction: "column",
    gap: "l",
    children: [
      {type: "text", value: "Apps", size: "l", weight: "strong"},
      installed.length > 0
        ? {
            type: "grid",
            columns: posture === "hand" ? 2 : 4,
            gap: "m",
            children: installed.map((tincture) => ({type: "control", effect: {open: tincture.ref}}))
          }
        : {type: "text", value: "No apps are installed yet.", tone: "muted"},
      {type: "text", value: "Recent runs", size: "l", weight: "strong"},
      runs.length > 0
        ? {
            type: "table",
            columns: [
              {key: "component", title: "Component"},
              {key: "status", title: "Status"},
              {key: "duration", title: "Duration (ms)"},
              {key: "error", title: "Error"}
            ],
            rows: runs.map(row)
          }
        : {type: "text", value: "No runs yet.", tone: "muted"}
    ]
  }
}

function row(run) {
  return {
    component: cell(run.reference),
    status: cell(run.kind),
    duration: Number.isFinite(run.duration_ms) ? run.duration_ms : null,
    error: run.error && typeof run.error === "object" ? cell(run.error.message) : null
  }
}

// A table cell is text of at most MAX_CELL characters, or nothing.
function cell(value) {
  if (typeof value !== "string") return null
  const characters = Array.from(value)
  return characters.length > MAX_CELL ? characters.slice(0, MAX_CELL).join("") : value
}

# The canvas proof

`run.sh` proves, in real browsers, the canvases a person sees in the Prism
shell as they are now built: each canvas is an ordinary HTML page in a
sandboxed iframe, written through `canvas.write` on the vanilla template or
shipped as a tincture page, drawn by the shell and spoken to over the
SDK. It drives the shipped canvas and the canvases written for the person,
switched by the shelf's switcher, the chords and a swipe on the shelf; a candle feed the
page draws itself; an app opened full over a canvas and frozen on a switch;
a hidden canvas that reads and acts on nothing and refreshes when shown
again; validation that keeps the working version when a candidate is not
ready or dies, and the fallback after a live crash, its window kept
and its kept version restored; the
activation the shell forwards a press under; a rebound feed; and the
canvas page's own policy against the browser, in Chromium, Firefox and
WebKit alike.

## The contract

- **SQLite only.** The proof runs one release on a SQLite database
  (`tests/release-boot/`) through the browser harness (`tests/browser/`),
  as the other proofs do. It establishes the surface and the browsers'
  behaviour, not adapter parity: every persistent operation its fixture
  performs has an ExUnit case run on both adapters in the module that owns
  it. Nothing here claims PostgreSQL.
- **No run executed.** The proof starts no execution worker and no model.
  Every feed result it shows is a fixed result its fixture accepted
  through the gate's own accept path, the one a fire takes once its run
  answered (`fixture.exs` `accept`). The scheduler's own fires of the
  bound feed fail for want of an execution worker and accept nothing,
  which `failed_fire` reads.
- **No credential in the record.** No bearer, token, cookie or credential
  value appears in the record, this README or the printed table. Each
  observation is redacted as it is noted (asset credentials in addresses,
  the SDK digest, signed tokens, bearers and every secret the run held),
  and the record's own checks refuse one that carries any. The frame
  credential the fixture mints for the `policy` step is shown only by its
  refusal and never printed. On every exit path, an early exit, an
  interrupt or a stop included, `run.sh` looks for the session token, the
  cookie and every bearer the fixture minted in both records and removes a
  record that carries one; then it removes the answer files, the one place
  a minted bearer was kept.

## Running it

```
CANVAS_PROOF_VIEWPORT=desktop tests/canvas-proof/run.sh
CANVAS_PROOF_VIEWPORT=720x720 tests/canvas-proof/run.sh
```

`desktop` is the PC (1280×900, posture `desk`); `720x720` is the phone
(posture `hand`). Any other value fails the run before the server starts.
`CANVAS_PROOF_HOST_CLASS` names the host class the measurement is held to
(below): `reference`, the default when it is unset, or `github-hosted`,
which CI's canvas proof step sets; any other value, an empty one included,
fails the run before the server starts. The release is built as the
release proofs build it (MIX_ENV=prod, SQLite); `RELEASE_BOOT_SKIP_BUILD=1`
reuses one a previous run built. The record, `canvas-proof.json` and
`canvas-proof.md`, is written into `PROOF_OUT` (default: the scratch
directory, kept with `RELEASE_BOOT_KEEP=1`), and the table is printed.
`CANVAS_PROOF_DEV` narrows a local run (`browsers=…;steps=…;measure=0`); its
record says it is narrowed and never passes.

What the person does goes through the console's own path and the gate
(the release fixture's `console`): the layout, `canvas.write`, `feed.bind`,
`feed.remove` and `feed.press`. A tincture's page, a canvas's validation
and open among them, opens only under its owner's grant, so the person
grants each published tincture and each written version before the proof
shows it, through the release fixture's `grant`, the consent walk's plan,
preview and commit. Where a version reads a stream the working version
does not, the shell's own grant prompt asks again, and the steps that meet
it confirm it in the prompt (`validation_failures`, `crash_fallback`).
`fixture.exs` holds the rest, which a person cannot do from a browser and a
run would otherwise do: the feed's source and its profile, each fixed
result, the feed's row as the store reads it, the scheduler's failed fire,
and a canvas frame credential for the `policy` step. `proof.mjs` asks for
each mid-run through the output directory (`ask-N.json`, each the command
and its non-secret arguments), and `run.sh`, which holds the session
token, answers `answer-N.json`.

## The tinctures and the canvases

- **The shipped canvas** `tincture:local.canvas` (0.3.0), the layout's
  first canvas, placed under the id `start`: its React page draws the day
  in one sentence, what needs attention grouped by cause, the recent runs,
  a launcher for each installed tincture (`button.app` with the name in
  `.label`) and the schedules, from the bus.
- `canvas-full`: an ordinary tincture, opened full over a canvas from the
  shipped canvas's launcher tile, and on the desk `markets`' column app,
  the sibling frame the `activation` step clicks in. In the hand a column
  app is laid over the whole canvas, so `markets` has none there.
- `canvas-probe`: a canvas page (`tinctures/canvas-probe/`) that reads the
  feed `candles` and draws its candles as its own SVG, tags each feed event
  it reads with the state the shell last told it (`cyfr.on("state")`),
  keeps a counter running on a timer, opens an app from its own button,
  and offers the `policy` step its page-own requests: a script element
  with a foreign `src`, a fetch its `connect-src` refuses, a peer
  connection to the proof's UDP listener, and a malformed `open` posted
  over its port.
- `canvas-broken`: a canvas page whose working version (1.0.0) becomes
  ready; each later version, written with `canvas.write`, never becomes
  ready, dies before ready, or reloads its own frame after ready, as its
  page says.
- `markets`, `measure`, `written`: canvases written with `canvas.write` on
  the vanilla template. `markets` draws the feed `candles` and presses the
  feed's refresh action from a button the person clicks, and asks for the
  grant of `catalyst:local.claude` from another; `measure` is one
  line the measurement opens; `written` is the canvas `written_canvas`
  writes.

The feed is `candles` (actions `buy`, a run, and `refresh`), bound through
the console at 60 minutes on the fixture's source `catalyst:local.candles`,
the suite's catalyst guest, whose answer is no feed envelope, so a fire's
result is refused.

## The steps

Each step is recorded by name with the browsers it runs on, its
observation and its result. Chromium runs every step; Firefox and WebKit
also run the browser-behaviour steps (`activation`, `grant_control`,
`rebound_control`, `connection_allowlist`, `policy`). A browser that cannot launch fails its
steps and is recorded absent, never as a pass. Every wait is bounded. What
reached the server is read from the harness's proxy, which every request
of the browsers passes through; what the shell received is read from the
instrument (below).

A click a step makes in a canvas frame for an `open` or a `press` the
shell must forward is a person's click: the button goes down at the point
the target was measured at on the frame shown at that moment, and comes up
once the shell's document holds that frame as its active element (at most
2 s later), so the page sends its verb from its own click handler some
moments after the click focused the frame, as a person's click does.
Playwright's own click sends the button's down and up at once. In
Chromium the canvas's frame runs in a process of its own, and the shell
learns that the click focused it by way of the browser process, which on a
loaded host can come after the verb the page sends over its port, so the
bridge drops the verb, the frame not yet being its active element. Nothing
is evaluated on a frame while the button is down, and what the shell
received is read once it has handled the verbs the click sent.

| step | what holds, and how it is seen |
|---|---|
| `two_canvases` | the switcher lists the shipped canvas (`start`) and a written one (`markets`); the shipped canvas's working version is shown live drawing its launchers, and the written one is validated (its validation frame's `ready`, one), activated (working 0.1.0) and shown live, and the canvas left is frozen |
| `attention_moves` | the shipped canvas, its runs stream answered with three failures a grant fixes and one long unrelated failure, moves Needs attention to the other column when a window is reported over it, and Recent runs, Apps and Schedules stand exactly where they stood; in the hand every section stands in one column |
| `switch` | the shelf's switcher, `Ctrl+Alt+1` (from markets, whose window on the desk is the active app, which the arrows would tile), `Ctrl+Alt+ArrowLeft` and `Ctrl+Alt+ArrowRight` (at `start`, which has no active app), and a swipe each way along the shelf (a touch swipe in the hand, a pointer drag on the desk) each move the shown canvas, resuming the frame a canvas held; the canvas left is frozen and inert; leftward at the first canvas does nothing, so nothing wraps |
| `written_canvas` | a canvas written with `canvas.write` at 0.1.0 is validated in its own frame (ending on `ready`), activated (working 0.1.0, nothing failed) and opened live at that version, drawing its version |
| `feed_chart` | the feed `candles`' fixed result is drawn by the probe page as six candles at the accepted revision; the observation says the result is fixed and no run executed |
| `app_over_canvas` | `canvas-full` opens full from a person's click on the shipped canvas's launcher tile (one forwarded `open`), the canvas under it frozen; on a switch the full frame is frozen and inert; switched back it is live again over its canvas, and closing it shows the canvas's same frame live |
| `window_drag` | on the desk, markets's window (canvas-full) dragged by its title bar behind the shield is drawn where it was dropped, and the layout tool reads it back at a newer revision at that geometry; in the hand no title bar, window or tile is drawn |
| `tile_narrows` | on the desk, the window's tile control tiles it, and the canvas's frame narrows by the tile's width; in the hand no title bar, window or tile is drawn |
| `covered_windows` | on the desk, the canvas is told the dragged window's rectangle in its own pixels and nothing else, and nothing once the window is a tile; in the hand it is told nothing covers it |
| `frame_kept` | on the desk, the window's iframe is the same element under the same frame id, with no new load, after it is raised from the shelf, tiled, made full and made a window again with Ctrl+Alt+ArrowDown; in the hand markets places no window |
| `hidden_canvas` | switched away, the probe's frame is frozen and the probe hears `state` `frozen`; from then no stream open of it reaches the server, a feed result accepted while it is hidden reaches its closed stream not, and a press it sends is dropped (its frame's `data-dropped` moves, the shell receives nothing), a count that outlives another switch while it stays hidden, which draws its iframe again; switched back, its stream refreshes to the new result. Every feed event the probe read is tagged with the state the shell last told it, and none is tagged `frozen`. Nothing asserts the page's JavaScript stopped |
| `validation_failures` | `canvas-broken` 1.0.0 is working; a later version that never becomes ready is recorded `not_ready` at its deadline, and one that dies before ready (the shell's receipt of its validation frame's `failed`) is recorded `died`; each later version reads a stream 1.0.0 does not, so once its validation fails the working version, 1.0.0, opens nothing (the canvas shows its `ungranted` refusal) and the shell's grant prompt asks for 1.0.0 itself; the person confirms it and 1.0.0 opens; neither falls the canvas back: no fallback line is drawn |
| `crash_fallback` | a version that becomes ready is activated, then its live frame loads a second time after `ready()` (the page reloads itself, the frame's death, and posts no `failed`: none reaches the shell): the shipped canvas shows in its place, the window over it on the desk stays open as the same frame, and AQUA's control is as it was; one line in the shelf's area reads "Your canvas stopped. Showing the standard one." and offers Try again and Restore the last working one; the kept version reads no stream, so restoring it raises the grant prompt for the kept version, with nothing restored meanwhile; the person confirms it, the kept version is restored and opens, and the line goes |
| `activation` | a person's click on the press button dispatches one `press`, inside the click, forwarded with the shell's activation active and the canvas its active element; several presses inside one click are each forwarded; a press the page sends with no input, and one held 8 s past the click, are each dropped (the frame's `data-dropped` moves, the shell receives nothing). Recorded per browser, no drop asserted: a press after a click elsewhere in the shell, and after a click in a sibling frame (on the desk; the hand has no sibling beside the canvas, which the record says), each with the canvas focusing itself by `window.focus()` and by an element's `focus()` and with neither |
| `grant_control` | the markets canvas's grant control, clicked by the person, sends one `grant`, which the shell receives inside the click with its activation active and the canvas its active element, and forwards; the same request sent from a timer with no input near it is dropped (the frame's `data-dropped` moves). The shell's offer of the grant in the system layer is not checked yet: the shell handles the verb in a later change, and the record says so |
| `rebound_control` | while the binding is live, a press names it; the feed is removed and bound again with other arguments and a new binding id; `feed.press` naming the old binding is refused `not_found`; the canvas's stale press still names the old binding; once a result of the new binding reaches the canvas, its press names the new binding and the shell forwards it. Each press is sent from the page's click handler inside a person's click on the press button, measured on the frame shown at that moment, and the record carries what the shell did with each: how many it received, forwarded and dropped, and whether it held activation and the frame as its active element. The probe and markets open their feed stream again whenever it closes, and the step switches markets away and back before it waits, so the new binding reaches it on a reopened stream's refresh. That is because an open feed stream was once seen to keep its old binding after a rebind (one debug run, not proven): an open finding on the follow-up list, which a unit check would settle (after a rebind, an open feed stream delivers the new binding's results or closes). The step does not show what an open stream does across a rebind, and its record says so |
| `connection_allowlist` | under the canvas page's `connection-allowlist` header the SDK loads and runs, the page's own stylesheet loads and applies, and the feed stream opens and delivers, in all three browsers |
| `policy` | ordinary requests and checks on a canvas open, none framed as an escape (below) |
| `disconnect` | the phone's or the PC's socket is cut: the canvas is marked disconnected, still drawn, and its frame is inert; regained, the canvas is live and the shell switches again |
| `failed_fire` | a feed bound at one minute for this step alone: the fixture claims a seq, the scheduler's own fire at the due minute claims a later one and ends with an error, having run nothing and accepted nothing, and the fixture's claim is then accepted; the step records the seqs, the fires' runs and errors, and whether the accepted seq moved, and the binding is removed. Why a fire failed is not observable: the store keeps no reason for a fire's error |

The steps run in this order in each browser: the first six on the shipped
canvas, the probe and the written canvases, then `activation`,
`grant_control`, `rebound_control`, `connection_allowlist` and `policy`,
then the steps on `canvas-broken` (whose validation fails or whose frame
dies into the fallback), the socket cut and the scheduler's fire.

### `policy`, each check

Each is an ordinary request on a canvas open, read as the harness or the
server sees it; none tries to leave the sandbox.

- **The page's policy as served.** The canvas page is fetched from the
  harness (not from inside the frame), and its `Content-Security-Policy`'s
  `script-src` is exactly the version's files prefix and the SDK's one
  path, its `connect-src` exactly the open's data path and the version's
  files prefix; the `connection-allowlist: (response-origin)` header is
  present and no `access-control-allow-origin` header is.
- **A foreign script element.** A script element the page creates with a
  `src` on `attacker.test` does not load (its `error` event fires), and no
  request for it reaches the harness's recording endpoint, in all three
  browsers.
- **A fetch the policy refuses.** A fetch from the page to a public invoke
  URL and to a webhook URL of the site is refused by `connect-src` before
  it is sent, so no request reaches the proxy (§6 row 9h).
- **The connection allowlist.** The page opens an `RTCPeerConnection` to
  the proof's UDP listener, on loopback: in Chromium no UDP packet arrives
  under the page's `connection-allowlist`; in Firefox and WebKit the
  packets that arrive are recorded as the disclosure P1 (a) accepts (§6 row
  9g). A browser other than Chromium that sends the loopback listener
  nothing, Firefox as run here, is recorded as not demonstrating the
  disclosure against loopback, and the canvas plan's Appendix A.3
  measurement against a non-loopback address (12 packets from Firefox,
  with the header and without) stands.
- **No write route.** A canvas credential on the shared invoke route is
  refused `canvas_path_required`; a credential of another open on this
  canvas's data path is refused `frame_path_mismatch` before any authority
  is derived; and the canvas's own data path has no invoke route (404)
  (§6 rows 9i and 9j).
- **An open carrying arguments.** An `open` carrying arguments beyond
  `ref`, posted over the port by the page, is dropped by the bridge: none is
  forwarded, no tincture opens and the frame's `data-dropped` moves (§6 row
  9k).

## Containment shown elsewhere

The confinement of a canvas's code against the host page, its siblings and
other served versions is not driven here. The sandbox exits that depend on
the frame being a sandboxed page, not a canvas, are the hostile-frame
proof's (`tests/hostile-frame-proof/`): navigating itself to a foreign
origin or within the site (`self_navigation_foreign`,
`self_navigation_site`), a page that reads the session refusing a framed
request (`self_navigation_session_page`), a post to a sibling frame
(`sibling_message`), and the frame-identity checks. The canvas-specific
rows are the canvas proof's own, in `policy` and `connection_allowlist`
above: the page's served policy, a foreign script element, a fetch
`connect-src` refuses (9h), the connection allowlist against a peer
connection (9g), the data routes' refusals of a canvas credential (9i,
9j), and an `open` carrying arguments (9k), with the SDK, the page's
assets and its streams working under the header. The broader confinement
sweep that the former worker-policy drove is owed to a separate deliverable.

## The measurement

Recorded per viewport, in Chromium, on one clock: `performance.now()` in
the shell's document. An init script on the shell's page (Playwright's
`addInitScript`) records the mark of a switch click, in a capture-phase
`click` listener on a `#canvas-switcher button[data-canvas]`, which runs
before LiveView's handler pushes `switch_canvas`; and it wraps
`MessagePort.prototype`'s `onmessage` setter, so the handler the shell's
bridge sets on a frame's port is called through a wrapper that first
records `performance.now()` with the message's `verb` and `frame`, whether
the shell holds transient user activation, whether the canvas's iframe is
the active element, and whether the bridge dropped that message, then calls
the handler with the same event. The instrument changes no message and no
file of the shell, and records nothing of a boot, bearer, argument or
stream payload.

- A **frame open** runs from the switch click's mark to the shell's
  receipt of that canvas frame's `ready`: the click mark, then `ready` of a
  live canvas frame never seen before, with no validation frame's `ready`
  between. Each of the 20 samples shows a canvas with its working version
  already activated (`measure`), so the switch opens it live at once.
- A **validation** runs from the switch click's mark to the shell's
  receipt of the validation frame's `ready`, and the canvas then shows
  live. Before each of the 20 samples a new version of `measure` is
  written, so the switch validates it first.

Before the samples count, the instrument is checked on one validation and
one open: the marks fall in order; the open's `ready` comes from a live
canvas frame with no validation `ready` received before it; every message
the wrapper saw it handed on, the bridge dropped none, the version reached
Prism (the versions document's working version) and the canvas answers and
opens. A sample with no `ready` within 10 s fails the run, and no sample is
dropped from the counts. The record carries, per viewport, the date, the
host (its name, CPU model, core count and host class), Chromium's version,
the viewport, the sample counts (20 and 20), every sample, and the p50 and
p95 in milliseconds of each number, labelled with its clock.

**The budget.** Each number's p95 is bound to its canvas budget
(`ARCHITECTURE.md` §6.9 names the two) for the run's host class, at both
viewports: on the `reference` class, the host the budget was stated on, a
frame open within 100 ms and a validation within 100 ms; on the
`github-hosted` class, the GitHub-hosted runner, each within 150 ms. A run
names its class with `CANVAS_PROOF_HOST_CLASS` (`reference` when unset),
which `run.sh` hands the proof, and the record carries it as `host.class`.
A p95 over its class's budget, or a measurement with no p95 to hold to it,
fails the record's checks, and the run exits non-zero naming the number,
its p95, the viewport, the class and its budget. A record naming no class,
or a class the proof has no budget for, fails, never passing by default.
The budget is the proof's own (`BUDGET_MS`, keyed by class); the record
carries its class's row beside the measurement, and its checks hold the
record to the proof's budget, never to the record's copy.

## The record's own checks

`canvas-proof.json` fails the run if it carries a step reported without its
observation, a browser shown other than absent where it never launched, a
feed result reported as an executed run (or a fire that ran), any
PostgreSQL claim, a measurement without its date, host (with its core
count) and sample counts, a host class with no budget, a p95 over its
class's budget or none to hold to it, or any credential value: a secret
the run held, an asset credential in an address, a signed token or a
bearer. A narrowed run's record never passes. `run.sh` then looks for the
session token, the cookie and every bearer the fixture minted in both
records, and removes a record that carries one. `node proof.mjs
--check-record RECORD_JSON [SECRETS_JSON]` runs the record's checks over a
saved record, without a browser.

## Not driven

- **A successful press.** The proof starts no execution worker, so the
  runs a press starts fail; the press steps show what is dispatched,
  forwarded and refused, and the owning module's tests hold a press that
  runs.

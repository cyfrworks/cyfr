# The canvas proof

`run.sh` proves, in real browsers, the canvases a person sees in the Prism
shell: the shipped canvas and the canvases written for them, switched by
the switcher, the chord and the edge strip; a candle feed drawn by the
chart element; an app opened full over a canvas and frozen on a switch; a
canvas's worker stopped when its canvas is hidden; validation that keeps
the working version when a candidate answers no tree or dies, and safe
mode's kept version after a crash; the toolkit's controls, labels and
presses; and the confinement of a canvas's code, against the real host
page, toolkit and served versions, in Chromium, Firefox and WebKit alike.

## The contract

- **SQLite only.** The proof runs one release on a SQLite cell
  (`tests/release-boot/`) through the browser harness (`tests/browser/`),
  as the other proofs do. It establishes the surface and the browsers'
  behaviour, not adapter parity: every persistent operation its fixture
  performs has an ExUnit case in a C row below, run on both adapters in
  its own target. Nothing here claims PostgreSQL.
- **No run executed.** The proof starts no execution worker and no model.
  Every feed result it shows is a fixed result its fixture accepted
  through the gate's own accept path, the one a fire takes once its run
  answered (`fixture.exs` `accept`). C8 and C13 hold real executions. The
  scheduler's own fires of the bound feeds fail for want of an execution
  worker and accept nothing, which `failed_fire` reads.
- **No credential in the record.** No bearer, token, cookie or credential
  value appears in the record, this README or the printed table. Each
  observation is redacted as it is noted (asset credentials in addresses,
  signed tokens, bearers and every secret the run held), and the record's
  own checks refuse one that carries any. `exits`' "another frame's
  bearer" is shown by its refusal and never printed. On every exit path,
  an early exit, an interrupt or a stop included, `run.sh` looks for the
  session token, the cookie and every bearer the fixture minted in both
  records and removes a record that carries one, so no kept or uploaded
  record holds it, and both records when an answer cannot be read or
  parsed; then it removes the answer files, the one place a minted bearer
  was kept.

## Running it

```
CANVAS_PROOF_VIEWPORT=desktop tests/canvas-proof/run.sh
CANVAS_PROOF_VIEWPORT=720x720 tests/canvas-proof/run.sh
```

`desktop` is the PC (1280×900, posture `desk`); `720x720` is the phone
(posture `hand`). Any other value fails the run before the cell starts.
`CANVAS_PROOF_HOST_CLASS` names the host class the measurement is held to
(below): `reference`, the default when it is unset, or `github-hosted`, which
CI's canvas proof step sets; any other value, an empty one included, fails
the run before the cell starts.
The release is built as the release proofs build it (MIX_ENV=prod,
SQLite); `RELEASE_BOOT_SKIP_BUILD=1` reuses one a previous run built. The
record, `canvas-proof.json` and `canvas-proof.md`, is written into
`PROOF_OUT` (default: the scratch directory, kept with
`RELEASE_BOOT_KEEP=1`), and the table is printed. `CANVAS_PROOF_DEV`
narrows a local run (`browsers=…;steps=…;measure=0`); its record says it
is narrowed and never passes.

What the person does goes through the console's own path and the gate
(the release fixture's `console`): the layout, `canvas.write`, `feed.bind`,
`feed.remove` and `feed.press`. A tincture's frame, a canvas's validation
and activation among them, opens only under its owner's grant, so the
person grants each published tincture and each written version before the
proof shows it, through the release fixture's `grant`, the consent walk's
plan, preview and commit; a written version that reads what the grant
names already asks nothing. Where a version reads other streams than the
grant names, the shell's own grant prompt asks again, and the steps that
meet it confirm it in the prompt (`validation_failures`,
`crash_safe_mode`). `fixture.exs` holds the rest, which a
person cannot do from a browser and a run would otherwise do: the feed's
source and its profile, each fixed result, the feed's row as the store
reads it, the scheduler's failed fire, and the foreign bearer. `proof.mjs`
asks for each mid-run through the output directory (`ask-N.json`, each
the command and its non-secret arguments), and `run.sh`, which holds the
session token, answers `answer-N.json`.

## The tinctures and the canvases

- **The shipped canvas** `tincture:local.canvas`, the layout's first
  canvas (`home`): recent runs and a launcher for each installed tincture.
- `canvas-full`: an ordinary tincture, `home`'s full app, opened from the
  shipped canvas's launcher.
- `canvas-neighbour`: the colluding sibling, `probe`'s column app. An
  ordinary tincture with a connect origin and a script at a same-site
  path, which posts a forged handshake and `installed` to every frame
  beside it and listens on the channel a canvas might broadcast on.
- `canvas-probe`: a canvas whose module keeps a rendered counter, reads the
  feed `candles` and attempts every exit from the toolkit's module worker.
  Its version also holds `canvas-neighbour`'s `shared.js`, which its module
  imports statically as its own sibling file.
- `canvas-broken`: a canvas whose one module answers its tree, answers no
  tree, dies on its stream's fixture, or crashes live on an accepted
  result, chosen by the feed each version declares. 1.0.0 is published;
  each later version is written with `canvas.write`.
- `markets`, `labels`, `measure`, `written`: canvases written with
  `canvas.write`. `markets` draws the feed `candles` as a candle chart
  with its two actions as look-alike controls; `labels` draws the same
  two controls, and its module can post a binding record of its own;
  `measure` is one line of text the measurement opens; `written` is the
  canvas `written_canvas` writes.

The feeds are `candles` (actions `buy`, a run, and `refresh`),
`broken-die` and `broken-crash`, bound through the console at 60 minutes
on the fixture's source `catalyst:local.candles`, the suite's catalyst
guest, whose answer is no feed envelope, so a fire's result is refused.

## The steps

Each step is recorded by name with the browsers it runs on, its
observation and its result. Chromium runs every step; Firefox and WebKit
also run `exits`, `worker_policy`, `labels`, `activation_once` and
`rebound_control`. A browser that cannot launch fails its steps and is
recorded absent, never as a pass. Every wait is bounded. What reached the
server is read from the harness's proxy, which every request of the
browsers passes through; what the shell received is read from the
instrument (below).

| step | what holds, and how it is seen |
|---|---|
| `two_canvases` | the switcher lists the shipped canvas and a written one; each is validated (one validation frame's `tree`), activated (its versions document's working version) and shown live, and the canvas left is frozen |
| `switch` | the switcher, `Ctrl+Alt+ArrowLeft` and `Ctrl+Alt+ArrowRight`, and a swipe each way along the edge strip (a touch swipe in the hand, a pointer drag on the desk) each move the glass, resuming the frame a canvas held; the canvas left is frozen and inert; leftward at the first canvas does nothing, so nothing wraps |
| `written_canvas` | a canvas written with `canvas.write` at 0.1.0 is validated in its own frame, activated (working 0.1.0, nothing failed) and opened live at that version |
| `feed_chart` | the feed `candles`' fixed result is drawn by the chart element as six candles at the accepted revision; the observation says the result is fixed and no run executed |
| `app_over_canvas` | `canvas-full` opens full from the shipped canvas's launcher (one `open`), the canvas under it frozen; on a switch the full frame is frozen and inert; switched back it is live again over its canvas, and closing it shows the canvas's same frame live |
| `worker_stop` | switched away, `canvas-probe`'s module worker is terminated (the browser closes it) and the counter stops where it was; switched back, the same frame starts a new generation, whose counter ticks and whose stream delivers its refresh |
| `validation_failures` | `canvas-broken` 1.0.0 is working; a later version that answers no tree is recorded `no_tree` at its deadline, and one that dies on its stream's fixture (the shell's receipt of its validation frame's `failed`) is recorded `died`; each later version reads a stream 1.0.0 does not, so once its validation fails the working version, 1.0.0, opens nothing (the canvas shows its `ungranted` refusal) and the shell's grant prompt asks for 1.0.0 itself; the person confirms it in the prompt and 1.0.0 opens |
| `crash_safe_mode` | a version that answers its fixture is activated, then crashes live on the feed's accepted result: safe mode `crashed`, offering retry, the kept version and the shipped canvas; the kept version reads no stream, so choosing it raises the grant prompt for the kept version in front of safe mode, with nothing restored and no canvas frame open; the person confirms it in the prompt, and the kept version is restored and opens |
| `exits` | each exit below, with what the worker saw and what reached the server |
| `worker_policy` | the eight results below, in each browser, with the browser's version |
| `labels` | two controls of one look show different labels, `Buy` and `Refresh`, each from its binding; a binding record the module posts itself, labelling `buy` as "Refresh", relabels nothing: every label seen until the canvas fails closed is the declared one, every control is disabled, the shell receives its `failed` and enters safe mode `crashed`, and a retry draws the declared labels again |
| `activation_once` | a genuine click on `Refresh` dispatches one `press`, inside the click; the same event dispatched again dispatches nothing. Enter held on the control dispatches one `press`, inside its first keydown; its three repeats dispatch nothing. The shell receives exactly those two presses, and once it has handled them the feed's claimed seq has advanced by exactly 2. The count opens with no scheduled fire of the feed due within 90 s (a nearer one is waited for until it ends), and the feed's `next_run_at`, the cursor a fire's claim advances, is the same at its close |
| `rebound_control` | while the binding is live, a press names it and reaches `feed.press`; the feed is then removed and bound again with other arguments, a new binding id, whose claimed seq is read once the scheduler's first fire of it has ended and no later fire of it is due within 90 s; its `next_run_at` is the same when the count closes. The control drawn before still names the old binding when pressed and the shell receives it; once the shell has handled it, the new binding's seq has not moved. The old binding is no longer live, and `feed.press` naming it is refused `not_found`. Once a result of the new binding draws a new tree, the control names the new binding, and after its press the new binding's seq has advanced by exactly the fixture's accept and that press |
| `disconnect` | the phone's or the PC's socket is cut: the canvas is marked disconnected, still drawn, and its frame is inert; regained, the canvas is live and the glass switches again |
| `failed_fire` | a feed bound at one minute for this step alone: the fixture claims a seq, the scheduler's own fire at the due minute claims a later one and ends with an error, having run nothing and accepted nothing, and the fixture's claim is then accepted; the step records the seqs, the fires' runs and errors, and whether the accepted seq moved, and the binding is removed. Why a fire failed is not observable: the store keeps no reason for a fire's error |

The steps run in this order in each browser: the first six, then
`exits`, `worker_policy`, `activation_once`, `rebound_control` and
`labels` (whose canvas fails closed, which is safe mode), then the steps
on `canvas-broken`, the socket cut and the scheduler's fire.

### `exits`, each with its observation

Each address the probe builds carries an `attempt` query naming the
attempt, so the proxy's account finds it.

- **Navigating the frame:** the worker has no `location.assign` and no
  `open`; assigning its location is refused; the frame's address does not
  change and no request reaches the server.
- **Messaging a sibling:** no `window`, `parent`, `top`, `opener`, `frames`
  or `document` in the worker; the neighbour hears nothing on the channel
  the probe broadcasts on.
- **The colluding sibling's message to the canvas frame:** the neighbour
  posts throughout, and none of it reaches the module: `installed` never
  names its forged tincture.
- **Importing `canvas-neighbour`'s script** at its real same-site path:
  `import()` and `importScripts()` are refused, and no request for it
  reaches the server.
- **A redirect from an allowed canvas or version address to a forbidden
  one,** for fetch (variants of the open's data path) and for script
  (variants of the version's directory, and an address naming the
  neighbour's script as its `next`): no request is answered 3xx, and none
  reaches the forbidden address.
- **A worker `RTCPeerConnection`:** absent, and no packet at the proof's
  local UDP listener.
- **A fetch to a public invoke and to a webhook path:** refused, and no
  request reaches the server.
- **A write on the data routes:** the open's path has no invoke or action
  route (its preflight is answered 404), its stream route refuses a write
  (400), and the shared action route is refused before any request.
- **Another frame's bearer on the canvas's own route:** answered 403
  `frame_path_mismatch`, the refusal made before any authority is
  derived.
- **An open with data:** the toolkit's grammar refuses the whole tree: for
  a second, four times the toolkit's longest wait before it draws, nothing
  of it is drawn, nothing is opened and the canvas does not fail; the next
  tree draws.

### `worker_policy`, the eight results

1. the frame's origin, and its module worker's, is `"null"`;
2. the module worker runs from a `blob:` address in its role, and the page
   holds the worker bundle as one inert `application/json` element beside
   its one executable script;
3. the stream request to the open's own data path is answered (200), and
   the module receives its refresh;
4. a request to another open's data path is refused before any request;
5. a `fetch` of a version file is refused before any request;
6. an `import()` and an `importScripts()` of a file under another
   credential's served prefix are refused before any request;
7. the version's module imports with a static import of a sibling file,
   served 200;
8. a URL worker of a version file, from the page or nested in the worker,
   never runs, and no request for it reaches the server. The browser
   refuses to construct it, or ends it in an error event, or it sends
   nothing for five seconds, which is read as never having run. Since the
   version's module cannot run as a classic worker, what can fail here is
   the request: the proxy sees none.

The record keeps each browser's version beside its eight results.

## The measurement

Recorded per viewport, in Chromium, on one clock: `performance.now()` in
the shell's document. An init script on the shell's page (Playwright's
`addInitScript`) records the mark of a switch click, in a capture-phase
`click` listener on a `#canvas-switcher button[data-canvas]`, which runs
before LiveView's handler pushes `switch_canvas`; and it wraps
`MessagePort.prototype`'s `onmessage` setter, so the handler the shell's
bridge sets on a frame's port is called through a wrapper that first
records `performance.now()` with the message's `verb` and `frame`, then
calls the handler with the same event. The bridge pushes `canvas_verb` to
Prism inside that handler, so the mark is both the shell's receipt and the
moment the message goes on to Prism. The instrument changes no message
and no file of the shell, and records nothing of a boot, bearer, argument
or stream payload.

- A **frame open** runs from the switch click's mark to the shell's
  receipt of that canvas frame's `ready`: the click mark, then `ready` of a
  frame never seen before, a live canvas frame, with no `tree` or `failed`
  between. Each of the 20 samples shows a canvas id with no frame held
  (`open1` … `open20`, each in its predecessor's place), on `measure`'s
  working version.
- A **validation** runs from the switch click's mark to the shell's
  receipt of that validation frame's `tree`, and the canvas then shows
  live. Before each of the 20 samples a new version of `measure` is
  written, and `val1` … `val20` each take their predecessor's place.

Before the samples count, the instrument is checked on one validation
and one open: the marks fall in order; the open's `ready` comes from a
live canvas frame with no `tree` or `failed` received before it, as the
instrument's receipts show; every message the wrapper saw it handed on,
the bridge dropped none, the `tree` reached Prism (the versions
document's working version) and the canvas answers and opens. A sample
with no `ready` or `tree` within 10 s fails the run, and no sample is
dropped from the counts. The record carries, per viewport, the date, the
host (its name and CPU model), Chromium's version, the viewport, the
sample counts (20 and 20), every sample, and the p50 and p95 in
milliseconds of each number, labelled with its clock. The host is its name,
CPU model, core count (`cores`) and host class (`class`), on the record and
on its measurement alike.

**The budget.** Each number's p95 is bound to its canvas budget
(`ARCHITECTURE.md` §6.9 names the two) for the run's host class, at both
viewports:
on the `reference` class, the host the budget was stated on, a frame open
within 100 ms and a validation within 100 ms; on the `github-hosted` class,
the GitHub-hosted runner, the same measurement on a slower host, each
within 150 ms. A run names its class with `CANVAS_PROOF_HOST_CLASS`
(`reference` when unset), which `run.sh` hands the proof, and the record
carries it as `host.class`, a fact of its run as its viewport is. A p95 over
its class's budget, or a measurement with no p95 to hold to it, fails the
record's checks, and the run exits non-zero naming the number, its p95, the
viewport, the class and its budget. A record naming no class, or a class
the proof has no budget for, fails, never passing by default. The budget is
the proof's own (`BUDGET_MS`, keyed by class); the record carries its class's
row beside the measurement, and its checks hold the record to the proof's
budget, never to the record's copy.

## The record's own checks

`canvas-proof.json` fails the run if it carries a step reported without
its observation, a browser shown other than absent where it never
launched, a feed result reported as an executed run (or a fire that ran),
any PostgreSQL claim, a measurement without its date, host (with its core
count) and sample counts, a host class with no budget, a p95 over its
class's budget or none to hold to it, or any credential
value: a secret the run held, an asset credential in an address, a signed
token or a bearer. A narrowed run's record never passes. `run.sh` then
looks for the session token, the cookie and every bearer the fixture
minted in both records, and removes a record that carries one.
`node proof.mjs --check-record RECORD_JSON [SECRETS_JSON]` runs the
record's checks over a saved record, without a browser.

## Not driven

- **A successful press.** The proof starts no execution worker, so the
  runs a press starts fail; the press steps show what is dispatched,
  received and claimed, and C13 holds a press that runs.

## Shown elsewhere

Each C row's cases run on both adapters, in the verification of the change
that owns them; this proof links them and does not run them.

| ID | Claim | Test file: cases |
|---|---|---|
| C1 | A foreign bearer on a canvas path is refused before authority is derived | `apps/cyfr/test/emissary/web/controllers/tincture_data_controller_test.exs`: `a canvas path refuses another frame's bearer before any charge or grant`; `a canvas path refuses a non-canvas frame` |
| C2 | The data routes refuse every invoke and operation for a canvas | same file: `the shared routes refuse a canvas credential`; `a canvas path has no invoke or action route` |
| C3 | No canvas or version path redirects | `apps/cyfr/test/emissary/web/controllers/canvas_controller_test.exs`: `no canvas page, data or served path answers a redirect` |
| C4 | The canvas policy is exactly the one its rules write, and the worker bundle is inert data | `apps/cyfr/test/compendium/tincture/rules_test.exs`: `the canvas policy names only the open's paths`; `canvas_controller_test.exs`: `the host page carries the canvas policy and the worker bundle only as inert data` |
| C5 | Validation answers fixtures and admits nothing | `tincture_data_controller_test.exs`: `a validation credential is answered from fixtures without an admission`; `a feed fixture follows the binding's result shape` |
| C6 | Activation consumes the credential once; a stale member activates nothing; the document publishes fenced | `apps/cyfr/test/compendium/canvas_test.exs`: `activation consumes its validation credential once`; `two activations over one revision publish one`; `a member that lost its slot activates nothing` |
| C7 | Restore applies today's grant | `canvas_test.exs`: `a kept version whose grant moved answers consent_required` |
| C8 | A feed result is accepted only by shape, size, seq and live fence | `apps/cyfr/test/opus/feeds_test.exs`: `a result outside its shape changes nothing`; `an earlier-started result never replaces a later one`; `a stale member writes no result` |
| C9 | The feed cap holds under concurrent binds, apart from schedules | `feeds_test.exs`: `concurrent binds stop at the cap`; `the schedule cap counts schedules only` |
| C10 | A feed publishes after commit, only an accepted result, on its athanor's one topic | `apps/cyfr/test/opus/providers/feed_test.exs`: `an accepted result is broadcast after its commit`; `a refused result broadcasts nothing`; `another athanor's subscriber hears nothing` |
| C11 | Delivery reads the refresh after subscribing, loses no racing event, and filters by the subject | `apps/cyfr/test/cyfr_web/sse_test.exs`: `a refresh is delivered first and an event racing it is delivered, deduplicable`; `a filtering stream delivers only its subject's payloads, refresh and live` |
| C12 | Bind refuses a profile that does not admit `schedule`; Aqua's bind always asks | `feed_test.exs`: `bind refuses a consent that does not admit schedule`; `an in-chain bind is never admitted without an approval` |
| C13 | A press runs under the component's grant; refresh publishes, run does not | `feed_test.exs`: `a refresh press publishes through the fence`; `a run press publishes nothing` |
| C14 | Controls bind at tree time, labels come from declarations, one activation dispatches once and at once | `apps/cyfr/assets/test/toolkit/controls.test.mjs`: `a control's label is never the canvas's`; `a binding record from the module's worker fails the canvas and relabels nothing`; `an untrusted or replayed event dispatches nothing`; `a press is dispatched inside its handler or not at all` |
| C15 | A canvas cannot declare background, and a hidden canvas is suspended whatever it declares | `rules_test.exs`: `a canvas declaring background is refused`; `apps/cyfr/test/prism/frames_test.exs`: `a hidden canvas is suspended whatever its declaration` |
| C16 | Validation tears down on tree, deadline, death and ownership loss; only a tree activates | `apps/cyfr/test/prism/canvas_validation_test.exs`: `a tree activates the version, and the trial is torn down`; `no tree by the deadline records no_tree, and the working version opens`; `a failure at any stage records died, and with no working version is safe mode not_validated`; `the frame's death records died`; `a member that lost its slot activates and records nothing, revokes the trial's credential, and is never safe mode` |
| C17 | Aqua writes a canvas through `canvas.write` from shapes and bindings | `apps/cyfr/test/aqua/canvas_write_test.exs`: `a scripted turn writes a new canvas version and reads no stream value` |
| C18 | The shipped canvas is the default; an empty layout draws the picker | `apps/cyfr/test/prism_web/live/shell_canvas_test.exs`: `a new person sees the shipped canvas`; `a layout with no canvas draws the picker` |
| C19 | A wrong digest consumes nothing | `apps/sanctum/test/sanctum/validation_credential_test.exs`: `a consume with the wrong digest changes nothing and the right one then succeeds` |
| C20 | Feed writes are fenced and tenant-scoped | `feeds_test.exs`: `create refuses a member that lost its slot after admission`; `a seq claim refuses a member that lost its slot after admission`; `removal refuses a member that lost its slot after admission`; `another athanor's actor reads, claims, accepts and removes nothing by a feed id` |
| C21 | No canvas credential survives scrubbing | `apps/cyfr/test/cyfr_web/plugs/scrub_tincture_credentials_test.exs`: `a canvas page credential is redacted, early refusals and malformed credentials included` |
| C22 | Concurrent writes never share or replace a version | `canvas_test.exs`: `two synchronized writes from one newest version get distinct versions or one conflict, and no version's bytes are replaced` |
| C23 | A control keeps its binding's identity | `controls.test.mjs`: `a control keeps the binding id it was bound to at tree time`; `feed_test.exs`: `after a rebind with different arguments, a press naming the old binding refuses` |
| C24 | Freezing stops the canvas's code | `apps/cyfr/assets/test/toolkit/worker.test.mjs`: `freezing terminates the worker and a counter stops; resuming imports the module again` |
| C25 | The ordinary credential, devices and grant-prompt guards hold in the shell | `apps/cyfr/test/prism_web/live/shell_prompts_test.exs`: all eight, the credential prompt's five (`from a frame that does not declare vault.create, a hidden frame or a frame this shell did not create, is dropped`; `a hidden frame with a background grant is not asked for either`; `dismissed, the frame is told only that nothing was saved`; `refused, the prompt stays open; closed, the frame is told saved: false and nothing else`; `confirmed, the entry is saved and the frame is told saved: true, never the value`), the devices prompt's (`opens the pairing prompt, once, listing the person's paired devices`) and the grant prompt's two (`a frame refused for want of a grant is offered the grant prompt, and opens once it is confirmed`; `dismissed, the frame keeps showing its refusal`) |

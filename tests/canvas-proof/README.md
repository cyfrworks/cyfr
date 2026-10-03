# The canvas proof

`run.sh` proves, on the browser harness (`tests/browser/`), the canvas a
person sees in the Prism shell: the shipped desktop in each posture, a full
frame over it, the vault page and its credential prompt, safe mode, the
system layer's prompts, and what stays drawn and what fails closed when the
LiveView socket or the whole server goes. It starts the `cyfr` release on
SQLite as the other proofs do, publishes the proof's tinctures
(`tinctures/`) privately in a signed-in person's athanor, publishes that
person's layout and seeds their vault through the release's own fixture
(`tests/release-boot/fixture.exs`, `vault`: entering a credential is a
sensitive change confirmed with a fresh proof, which this proof is not
about), and drives Chromium, Firefox
and WebKit (`proof.mjs`). The shipped desktop and vault come with the
release's seed tree.

The layout: in both postures the desktop is `tincture:local.desktop`, the
vault an icon, `canvas-card` (one static card) a card and `canvas-full` an
icon. The desk order is vault, card, full; the hand order is card, vault,
full. `canvas-stall` is a desktop that never sends `ready`.

## Expected outcomes

| Section | What holds |
|---|---|
| postures | a desk viewport (1280x800) and a hand viewport (390x844, touch) of the same person each report their posture, and the desktop draws its strip in that posture's order, with the card drawn from `card.refresh` and the vault as an icon, filling the canvas |
| full | `canvas-full`, opened from its icon on the desktop, covers the desktop; the desktop's frame is `frozen` and inert, and a call from it is refused as suspended; forty Tabs from the full frame's close control never land on a control the full frame covers (one the page shows the full frame over at its centre), the assistant's panel, which stays reachable by design, counted apart; closing the full frame makes the desktop live and acting again |
| vault | the vault page lists entry names, offers only Add entry and Refresh, and says entries are changed and removed on the console's vault page; Tab alone reaches its name field; typing a name and Enter opens the shell's credential prompt, which names the entry; typing the value and Enter asks for a fresh confirmation, a prompt naming `vault.create` and the entry. In Chromium the confirmation is given with a passkey (below): the prompt closes, focus returns to the vault's frame, the page is told it was saved and lists the entry. In Firefox and WebKit it is dismissed: the prompt closes, focus returns to the vault's frame, the page is told nothing was saved, and `vault.status` holds no entry of that name. In every browser the value is in no frame's document and in no request a frame made (`/_f/`, `/_s/`, `/t/`), read with their bodies at the harness's proxy |
| safe mode, chord | the section starts with no prompt open; Ctrl+Alt+S on the shell's page enters safe mode: every frame is gone, the picker is drawn, the prompt (`alertdialog`) takes focus; Enter on its first offer leaves safe mode and the desktop runs again |
| safe mode, stall | the shipped desktop publishes `canvas-stall` as the layout's desktop through its own `layout.edit`; the shell reads the layout again and opens it; ten seconds after its handshake without `ready` the shell enters safe mode ("Your desktop did not start"), every frame gone; Tab to the default offer and Enter publish the default and the shipped desktop is back |
| prompts | every prompt shown has a `role`, an accessible name (`aria-labelledby`) and a description (`aria-describedby`), holds focus when shown, and gives focus back when it closes — to the element that had it, or to the body when that element is gone |
| disconnect | the proxy cuts the LiveView socket (every WebSocket tunnel, and the long-poll fallback): the canvas is marked disconnected, the last layout stays drawn, every frame is inert, a frame's shell verb is dropped, and a frame's data action is refused once the server has ended the view and revoked its credentials; after the socket is restored the desktop acts again, as a new frame with a new credential |
| server gone | with a tab open in every browser at once, `run.sh` stops the release by its own stop: each canvas is marked disconnected with the last layout drawn (the same desktop frame, its strip whole), the stream the desktop held open ends, and a new action and a new stream fail closed |

What each browser covers. A passkey ceremony is Chromium's alone: its
virtual authenticator (`tests/browser/lib.mjs`, `virtualAuthenticator`)
makes the person's first passkey, registered from the settings page through
the system layer's ceremony within the first-method window of the fixture's
sign-in, and asserts it for the vault section's confirmation. A passkey
needs a secure context, and this cell answers as `cyfr.test` over plain
HTTP, so Chromium is launched treating that one origin as secure
(`--unsafely-treat-insecure-origin-as-secure`), in its full build
(`channel: "chromium"`), which honours that switch where its headless shell
does not; the server-gone section's tabs still use the headless shell.
Firefox and WebKit offer no
virtual authenticator to Playwright: in them the proof shows the
confirmation asked, that dismissing it saves nothing, and that the next
section starts with no prompt open. Every other section runs the same in
all three.

The release is stopped as an operator stops it, by its own stop
(`release.sh`'s `server_stop`), and `run.sh` answers the proof once the
release has exited and its listener is gone. A graceful stop closes the
listener and refuses every LiveView connect before it drains the sockets
it holds, so each tab, told to reconnect, meets a closed port, and none is
drawn anew by a server about to go. The section therefore shows what a
person's tab keeps when its server is stopped for good: the canvas marked
disconnected with the last layout drawn, and every stream and action
failing closed. In the record each tab's only events after the stop are
its refused reconnects.

## Measurements

Recorded, not gated, once, in the first browser of the run:

- `card.refresh` from the desktop through the endpoint, 50 in a row
  (p50, p95, p99);
- `vault.status` from the vault page through the endpoint, 200 calls at
  concurrency 16, in two batches of 100. The data routes hold every
  address to 120 requests a minute (`CyfrWeb.Plugs.TinctureRateLimit`) and
  every browser reaches the server from the proxy's one address, so each
  batch starts and ends a minute apart;
- `vault.list` and `vault.status` inside the server through the gate as the
  console calls them (`measure.exs`), 200 calls each at concurrency 16, on
  the SQLite cell, and on a PostgreSQL cell of a release built for
  PostgreSQL when `CANVAS_PROOF_PG_URL` names an existing database as a role
  that may create databases. Each burst is started just before the member's
  next lease renewal, and with it are recorded every renewal the member's
  claimant asked during the burst (from its call to its answer, and whether
  it renewed), whether the member held its slot at every sample and kept
  its generation, the most audit writers running at once against the
  node's cap, the most audit and control-plane requests waiting for a turn
  at SQLite's write lock, and the audit writes lost, by stage and kind.

One outcome of the measurement is gated: on the SQLite cell every renewal
asked during a burst renews, at least one per burst, the member keeps its
slot and its generation, and the release answers ready at once; the
browsers start on it straight after.

## Not driven

- **`vault.list` on the page's path.** Its consent class (`staging`) refuses
  a tincture frame; the page lists through `vault.status`, and `vault.list`
  is measured inside the server.
- **Touch gestures in the hand viewport.** The posture is asserted; the
  strip is not driven by touch.

## Record

Recorded on 2026-10-03 on `p1` (Ubuntu 26.04.1 LTS, kernel
7.0.0-34-generic, 16 cores, 60 GiB, Docker 29.1.3), in
`mcr.microsoft.com/playwright:v1.63.0-noble` pinned by digest in
`tests/browser/harness.sh`, on the SQLite cell: every assertion held in
Chromium 153.0.8010.12, Firefox 155.0 and WebKit 26.6, the browsers
starting straight after the in-server measurement, and the server-gone
section after the release's own stop. The PostgreSQL rows below are the
2026-09-27 run's, the last with `CANVAS_PROOF_PG_URL` set.
`canvas-proof.json`, written by each run, holds every fact behind a row.

| Fact | Chromium 153 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| desk strip | vault card full-app | vault card full-app | vault card full-app |
| hand strip | card vault full-app | card vault full-app | card vault full-app |
| desktop under a full frame | frozen, inert | frozen, inert | frozen, inert |
| the covered desktop's call | refused, `forbidden` (suspended) | the same | the same |
| 40 Tabs from the full frame's capsule: on a covered control (on the assistant's panel) | 0 (7) | 0 (0) | 0 (6) |
| Tab presses from the shell to the vault's name field | 15 | 1 | 15 |
| requests the frames made after the value was typed, and those carrying it | 2, none | 2, none | 1, none |
| frames held during safe mode, by chord and by stall | 0, 0 | 0, 0 | 0, 0 |
| safe mode for a desktop that never said ready, after | 10 075 ms | 10 109 ms | 10 048 ms |
| a desktop's action with the socket cut | refused, `unauthenticated` | the same | the same |
| the desktop acting after the reconnect | yes | yes | yes |
| server gone, after the release's own stop | marked, layout kept, stream ended, action and new stream `unavailable`; no rejoin, each reconnect refused | the same | the same |

The assistant's panel keeps its place below the full frame and in the Tab
order, by design; the landings on it are counted, not asserted.

Measurements:

| Operation | Path | p50 / p95 / p99 |
|---|---|---|
| `card.refresh`, 50 in a row | the desktop, through the endpoint (Chromium) | 5.4 / 6.4 / 8.6 ms |
| `vault.status`, 200 at concurrency 16 | the vault page, through the endpoint (Chromium) | 71.8 / 152.8 / 191.2 ms |
| `vault.list`, 200 at concurrency 16 | in the server, through the gate, SQLite | 48.0 / 146.6 / 166.5 ms |
| `vault.status`, 200 at concurrency 16 | in the server, through the gate, SQLite | 40.8 / 166.2 / 198.4 ms |
| `vault.list`, 200 at concurrency 16 | in the server, through the gate, PostgreSQL 16 (2026-09-27) | 41.1 / 55.0 / 66.9 ms |
| `vault.status`, 200 at concurrency 16 | in the server, through the gate, PostgreSQL 16 (2026-09-27) | 31.2 / 38.7 / 42.6 ms |

Each cell's vault held eleven entries. No call was refused.

What each in-server burst did to the SQLite member's lease (15 s, renewed
every 5 s) and to the audit:

| Burst | Renewals during it, call to answer | Slot held | Audit writers at once | Waiting for a turn, audit / control plane | Audit writes lost |
|---|---|---|---|---|---|
| `vault.list` | 1, renewed in 55 ms | at all 307 samples, generation 1 kept | 8 of 16 | 7 / 0 | none |
| `vault.status` | 1, renewed in 1 ms | at all 342 samples, generation 1 kept | 16 of 16 | 15 / 0 | none |

The `vault.status` burst filled the writer cap without a write refused:
the queue at the write lock reached fifteen waiters beside the one holder,
and the renewal asked during the burst renewed all the same.

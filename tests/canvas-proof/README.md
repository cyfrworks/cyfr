# The canvas proof

`run.sh` proves, on the browser harness (`tests/browser/`), the canvas a
person sees in the Prism shell: the shipped desktop in each posture, a full
frame over it, the vault page and its credential prompt, safe mode, the
system layer's prompts, and what stays drawn and what fails closed when the
LiveView socket or the whole server goes. It starts the `cyfr` release on
SQLite as the other proofs do, publishes the proof's tinctures
(`tinctures/`) privately in a signed-in person's athanor, publishes that
person's layout and fills their vault through the console's own operations
(`tests/release-boot/fixture.exs`, `console`), and drives Chromium, Firefox
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
| full | `canvas-full`, opened from its icon on the desktop, covers the desktop; the desktop's frame is `frozen` and inert, and a call from it is refused as suspended; closing the full frame makes the desktop live and acting again |
| vault | the vault page lists entry names; Tab alone reaches its name field; typing a name and Enter opens the shell's credential prompt, which names the entry; typing the value and Enter saves it; the prompt closes, focus returns to the vault's frame, the page is told it was saved and lists the entry; the value is in no frame's document and in no request a frame made (`/_f/`, `/_s/`, `/t/`), read with their bodies at the harness's proxy |
| safe mode, chord | Ctrl+Alt+S on the shell's page enters safe mode: every frame is gone, the picker is drawn, the prompt (`alertdialog`) takes focus; Enter on its first offer leaves safe mode and the desktop runs again |
| safe mode, stall | the shipped desktop publishes `canvas-stall` as the layout's desktop through its own `layout.edit`; the shell reads the layout again and opens it; ten seconds after its handshake without `ready` the shell enters safe mode ("Your desktop did not start"), every frame gone; Tab to the default offer and Enter publish the default and the shipped desktop is back |
| prompts | every prompt shown has a `role`, an accessible name (`aria-labelledby`) and a description (`aria-describedby`), holds focus when shown, and gives focus back when it closes — to the element that had it, or to the body when that element is gone |
| disconnect | the proxy cuts the LiveView socket (every WebSocket tunnel, and the long-poll fallback): the canvas is marked disconnected, the last layout stays drawn, every frame is inert, a frame's shell verb is dropped, and a frame's data action is refused once the server has ended the view and revoked its credentials; after the socket is restored the desktop acts again, as a new frame with a new credential |
| server gone | with a tab open in every browser at once, `run.sh` kills the release: each canvas is marked disconnected with the last layout drawn (the same desktop frame, its strip whole), the stream the desktop held open ends, and a new action and a new stream fail closed |

The release is killed rather than stopped: a graceful stop drains every
LiveView socket while its listener still accepts, and a tab that joins again
during the drain is drawn anew by a server about to go — new frames whose
credentials the server takes with it — which is not the case this section
proves.

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
  that may create databases.

## Not driven

- **Deleting and rotating from the vault page.** `vault.delete` is an
  interactive-consent mutation, which the gate refuses to a tincture frame
  (its auth method is `tincture`); the page calls it and shows the refusal.
  A rotation takes the new value, which a frame never holds, so the page
  offers none.
- **`vault.list` on the page's path.** Its consent class (`staging`) refuses
  a tincture frame; the page lists through `vault.status`, and `vault.list`
  is measured inside the server.
- **Touch gestures in the hand viewport.** The posture is asserted; the
  strip is not driven by touch.

## Record

Recorded on 2026-09-27 on `p1` (Ubuntu 26.04.1 LTS, kernel
7.0.0-34-generic, 16 cores, 60 GiB, Docker 29.1.3), in
`mcr.microsoft.com/playwright:v1.63.0-noble` pinned by digest in
`tests/browser/harness.sh`: every one of the 178 assertions held in
Chromium 153.0.8010.12, Firefox 155.0 and WebKit 26.6.
`canvas-proof.json`, written by each run, holds every fact behind a row.

| Fact | Chromium 153 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| desk strip | vault card full-app | vault card full-app | vault card full-app |
| hand strip | card vault full-app | card vault full-app | card vault full-app |
| desktop under a full frame | frozen, inert | frozen, inert | frozen, inert |
| the covered desktop's call | refused, `forbidden` (suspended) | the same | the same |
| Tab presses from the shell to the vault's name field | 15 | 1 | 15 |
| requests the frames made after the value was typed, and those carrying it | 2, none | 2, none | 1, none |
| frames held during safe mode, by chord and by stall | 0, 0 | 0, 0 | 0, 0 |
| safe mode for a desktop that never said ready, after | 10 073 ms | 10 106 ms | 10 046 ms |
| a desktop's action with the socket cut | refused, `unauthenticated` | the same | the same |
| the desktop acting after the reconnect | yes | yes | yes |
| server gone | marked, layout kept, stream ended, action and new stream `unavailable` | the same | the same |

Measurements:

| Operation | Path | p50 / p95 / p99 |
|---|---|---|
| `card.refresh`, 50 in a row | the desktop, through the endpoint (Chromium) | 4.7 / 5.6 / 9.4 ms |
| `vault.status`, 200 at concurrency 16 | the vault page, through the endpoint (Chromium) | 65.2 / 124.4 / 159.4 ms |
| `vault.list`, 200 at concurrency 16 | in the server, through the gate, SQLite | 37.6 / 162.8 / 203.0 ms |
| `vault.status`, 200 at concurrency 16 | in the server, through the gate, SQLite | 26.4 / 146.4 / 166.2 ms |
| `vault.list`, 200 at concurrency 16 | in the server, through the gate, PostgreSQL 16 | 41.4 / 57.1 / 65.2 ms |
| `vault.status`, 200 at concurrency 16 | in the server, through the gate, PostgreSQL 16 | 31.6 / 40.1 / 47.8 ms |

Each cell's vault held eleven entries. No call was refused.

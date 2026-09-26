# The tincture proof

`run.sh LOCUS_IMAGE [OPENS]` proves a game tincture end to end on the browser
harness (`tests/browser/`):

- **Built from source.** `game/` is a Vite-template tincture — Three.js, Rapier's
  WebAssembly module stepping in an inline (`blob:`) worker at a fixed timestep,
  GPU particles, a fixed set of lights, one sound decoded once, `pointer_lock`,
  `fullscreen` and `audio_autoplay` declared, and one save through a declared
  seeded catalyst. `package-lock.json` pins every package; `build.py` builds it
  with `npm ci && npm run build` in the Locus builds image over the build wire.
- **Published through the publish check.** The version (source, lockfile and
  the build's `dist/`) is registered private (`Compendium.Registry`, which runs
  `Compendium.Tincture.check_version/2`); its public address answers 404.
- **Opened from the shell.** `proof.mjs` signs in, opens the game from the
  Prism shell in Chromium, Firefox and WebKit, and checks the frame's
  `sandbox` (`allow-scripts allow-pointer-lock`), `allow`
  (`autoplay; fullscreen`) and its `/_s/` address; that Rapier stepped and
  the sound decoded; that the save passed the frame's checks and the gate
  answered it; and that the second open's assets came from the browser's
  cache (no request, or a conditional one).
- **Measured.** Frame-open (launch in the shell to the game's ready: first
  rendered frame after physics stepped and the sound decoded) and asset-fetch
  (each `/_s/` resource's Resource Timing duration) over OPENS warm opens (one
  signed-in context, the shell closing and launching again; the first open is
  not counted) and OPENS cold opens (a new context each).

## Record

Recorded on 2026-09-26 on `p1` (`tests/browser/README.md`) by `run.sh`, OPENS = 50, the
builds image `cyfr-locus:c1smoke` built from `Dockerfile.locus`.

| ms, p50 / p95 / p99 | Chromium 153 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| frame-open, warm | 297 / 318 / 323 (n=49) | 209 / 229 / 247 (n=49) | 130 / 176 / 182 (n=49) |
| frame-open, cold | 476 / 497 / 517 (n=50) | 376 / 436 / 444 (n=50) | 409 / 451 / 468 (n=50) |
| asset-fetch, warm | 1 / 15 / 29 (n=98) | 4 / 24 / 30 (n=98) | 1 / 6 / 6 (n=98) |
| asset-fetch, cold | 5 / 166 / 191 (n=100) | 29 / 184 / 192 (n=100) | 5 / 204 / 206 (n=100) |

| Observation | Chromium | Firefox | WebKit |
|---|---|---|---|
| Renderer | WebGL | none (headless Firefox has no WebGL; physics and sound ran) | WebGL |
| Pointer lock / fullscreen from a click and a key in the frame | both | pointer lock | neither (headless) |
| Second open, from the network | nothing | nothing | `sound.wav` again: WebKit's network cache stores no media response |
| The save | `unavailable` at `execution`: the harness runs no execution engine | same | same |

Pending:

- **The completed save.** The save is admitted past the frame's checks and
  dispatched by the gate; with no Opus worker in the harness it ends
  `unavailable`. A save that completes needs the worker beside the release
  and a seeded catalyst that reads the invoke input
  `{"operation", "params"}`, which no seeded catalyst does today.
- **Built by Aqua from the guideline.** Memory and model work are deferred and
  no provider key is configured, so the game is built once, from source.

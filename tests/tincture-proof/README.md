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
  The person grants it its whole ask through the consent walk (`grant` in
  `tests/release-boot/fixture.exs`), since the shell opens a tincture's
  frame only under its owner's grant.
- **Opened from the shell.** `proof.mjs` signs in, opens the game from the
  Prism shell in Chromium, Firefox and WebKit, and checks the frame's
  `sandbox` (`allow-scripts allow-pointer-lock`), `allow`
  (`autoplay; fullscreen`) and its `/_s/` address; that Rapier stepped and
  the sound decoded, and the scene rendered unless the browser has no
  WebGL (headless Firefox has none), which the record notes; that the save
  passed the frame's checks and the gate answered it; and that the second
  open's assets came from the browser's cache (no request, or a conditional
  one), media aside: WebKit's network cache stores no media response, so it
  fetches the sound again whatever the headers say. Chromium caches none of
  the frame's assets: it keys its HTTP cache by the requesting frame's
  site, which a frame without `allow-same-origin` has none of, so the proof
  holds it to fetching them again (`ASSETS_CACHED`), as a change of answer
  is read before it is accepted. The pointer lock and
  fullscreen a click and a key in the frame obtain are recorded, not held.
- **Measured.** Frame-open (launch in the shell to the game's ready: first
  rendered frame after physics stepped and the sound decoded) and asset-fetch
  (each `/_s/` resource's Resource Timing duration) over OPENS warm opens (one
  signed-in context, the shell closing and launching again; the first open is
  not counted) and OPENS cold opens (a new context each).

## Limits

- **The completed save.** The save is admitted past the frame's checks and
  dispatched by the gate; with no runtime in the harness it ends
  `unavailable` at `execution`. A save that completes needs the worker
  beside the release and a seeded catalyst that reads the invoke input
  `{"operation", "params"}`, which no seeded catalyst does.
- **Built by Aqua from the guideline.** The harness runs no model and
  configures no provider key, so the game is built once, from source.

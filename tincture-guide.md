# Tincture Reference

Build, test, and deploy tinctures for CYFR. A tincture is a browser frontend — HTML, JavaScript, CSS and whatever assets it ships, WebAssembly and audio included — that the Prism shell opens in a sandboxed frame. It reaches the server only through the Cyfr SDK (`window.cyfr`): it invokes the components it declares, runs the system actions it declares and opens the streams it declares, and CYFR resolves credentials, consent and execution server-side. A tincture never holds an API key, a session or a secret.

The lists in this guide — served types, frame capabilities, templates, the declaration grammar, the wire's routes and the SDK's calls — are the frame's rules (`Compendium.Tincture.Rules`) and the wire (`Prima.TinctureWire`) as they stand; the docs-drift test fails when one of them differs.

---

## How a Frame Opens

The shell is the one place a tincture's frame is created. Launching a tincture:

1. The shell reads the version's declaration and renders the frame's `sandbox` and `allow` attributes from the rules for the capabilities it declares: `allow-scripts` always, every other token or permission only for a capability declared, and never `allow-same-origin`, `allow-forms`, `allow-popups` or any `allow-top-navigation`. A declaration the rules refuse opens nothing.
2. The frame's page is a private tincture's entry under an **asset credential** in its path, or a public tincture's public address. No URL carries anything that opens more than the version's own files.
3. The shell mints a **frame credential** for this open, bound to the person, the tincture version and its release digest, the grant revision of the tincture's owner profile and a fresh frame id.
4. On the frame's first load the shell posts it one handshake carrying a `MessagePort` and the frame id, and sends the frame credential over that port only. The SDK accepts the handshake only from its parent window, and only once.

From then on the SDK sends data requests to the endpoint with the frame credential as a bearer, and the shell verbs (`open`, `close`, `title`, `ready`, `credential`) over the port. The shell listens to no window message; anything arriving on the port that is not a shell verb for that frame is dropped. A reload or a navigation inside the frame gets no second handshake: the frame is spent until the person opens the tincture again.

A frame hidden behind another is **suspended** unless it declares `frame.background`, and resumed when shown: a suspended frame's requests are refused (`frame_suspended`). A resume that fails revokes the frame's credential and the frame shows the refusal in place of its page. Closing the frame, the `close` verb, the registry no longer listing the tincture and the end of the shell's session each revoke its credential. A frame credential is also refused once the tincture's version or its owner profile's grant moved since the open (`frame_moved`): open it again.

### Private and Public

A tincture is private unless it has an active public consent profile. Publish one with `profile.publish` (the proof-bound consent walk) and unpublish by revoking it with `profile.revoke`; `tincture_visibility.get` reports the current answer. The manifest's `tincture.public` is a metadata hint only.

| | Private | Public |
|---|---|---|
| **Its files** | `/_s/<asset credential>/<publisher>/<name>/<version>/<file>`, only under a credential the shell minted for the person | `/t/<athanor>/<publisher>/<name>` and the files under it, to anyone |
| **Opened by** | the shell, for a member of its athanor | the shell, or anyone at its address |
| **Data requests** | the frame credential as a bearer | in the shell, the frame credential; at its address, the page names itself as `public` and sends no bearer |
| **Runs under** | the tincture's owner profile | the owner profile in the shell; its public profile at its address |

---

## The Canvas

The shell draws a person's **layout** (`layout.get`, `layout.edit`): per posture — `hand` under 768 CSS pixels wide, `desk` otherwise — one desktop tincture, the app slots and the floating tinctures. The shell opens the desktop as a frame filling the canvas, under every slot and floating frame; a person who never arranged one runs the shipped `tincture:local.desktop`, with the shipped vault (`tincture:local.vault`) as its one icon. A layout published anywhere — by the desktop, the assistant or safe mode — is read again by every shell the person has open.

### Sizes and placements

A slot holds one tincture at one of three sizes:

| Size | What is drawn |
|---|---|
| `icon` | the desktop draws the tincture's icon; activating it opens the tincture as a full frame |
| `card` | the desktop draws one of the tincture's declared `cards`, as data (below) |
| `full` | the tincture's own frame, at the slot's place |

A tincture floats over the desktop only when its declaration names `frame.placement: "float"`, and only where the layout puts it. A tincture runs as a desktop only when it names `frame.placement: "desktop"`; a desktop draws other tinctures' cards and reaches nothing of its own, so it declares no `tincture.connect` origin, no `caps.egress` and no component dependency.

### Cards

A card is data the desktop draws, never a frame. **`card.refresh`** (a `slot` and a `posture`) runs the card's `source` under the card tincture's own grant, projects the answer through the declaration (the `number` and `list` fields of the source's answer, the declared title, image and buttons) and answers it; a static card runs nothing. Each refresh is also delivered on the stream **`cards.refreshed`**, which is bound to its holder: a frame opens it with no subject, and it carries the refreshes of that person's own cards and nobody else's. **`card.press`** (a `slot`, a `posture` and a `button` index) fires the button's declared action with its fixed `args`, through the gate, under the person's context; a button never fires the `card` tool itself. A desktop declares `card.refresh`, `card.press` and the stream `cards.refreshed` to draw cards.

### Hidden, frozen and background frames

The frame the person looks at is live. With a full frame shown, every other frame — the desktop among them — is hidden, and a hidden frame without `frame.background: true` is frozen: its credential is suspended before its bridge is told, its element is inert, and its requests are refused as `frame_suspended` until it is shown again. A frame that declares the background grant keeps running hidden. A frame never raises itself: no verb places, sizes or raises a frame.

### Safe mode

A desktop that has not sent `ready` within ten seconds of its handshake, a desktop whose frame is refused at open, and the person's own ask — the shell's **Safe mode** button, or Ctrl+Alt+S on the shell's page, which a frame never hears — enter safe mode. Every frame is discarded with its credential, the picker is drawn, and the shell's prompt offers to try the current desktop again or, while some posture runs another, to use the shipped default. Choosing opens the desktop again from the layout as it then stands. The assistant's panel stays as it was.

### Secrets

A frame never asks for a secret and never holds one. **`cyfr.credential(name)`** asks the shell to prompt the person for a value to store in the vault as the entry `name`; the shell honours it only for a live, visible frame whose declaration lists `vault.create`, and drops it otherwise. The value is typed into the shell's own prompt and goes to the vault; the frame is told only that the prompt closed and whether an entry was saved (`{saved: true | false}`), never the value and never why nothing was saved.

---

## Addresses, Credentials and Headers

A public tincture is served at its address, `/t/<athanor>/<publisher>/<name>` (the athanor segment is `@<namespace>` for a person's athanor, the group's slug for a group's), with its files under it. The address follows the tincture's latest version.

A private tincture version's files are served only at `/_s/<credential>/<publisher>/<name>/<version>/<file>`. The asset credential is signed, opaque and URL-safe; it names the person, the version's release digest and a window (`asset_credential_window_s`), carries no secret, and is verified against its source's standing at every request — a session that ended, a key that was revoked, a person denied or an athanor archived refuses the next fetch. It stays one credential for one person and one version for the window, so a browser's cache holds across opens, and it opens nothing but that version's files: another version's path under it is not found.

Every tincture response carries:

- `Referrer-Policy: no-referrer`, so no tincture URL — a private one carries its asset credential — leaves in a `Referer`;
- `X-Content-Type-Options: nosniff` and `Access-Control-Allow-Origin: *` (the frame's origin is `null`; what authorizes a read is the URL, never the requesting origin);
- `Cache-Control: public, max-age=3600` for a public tincture's files, `no-cache` for its address, and `private, max-age=<n>` for a private version's files, `n` never above the seconds the credential has left;
- `Content-Encoding: gzip`, for a client that accepts it, on text, scripts, JSON, SVG, glTF and WebAssembly.

A path under `/_s/` is a credential. **No proxy may log `/_s/` paths.** The server redacts the credential segment from the request path before any log line, span or error report names it; the shipped `Caddyfile` keeps no access log, and a proxy placed in front of CYFR must keep none for these paths either.

Every HTML page of a version is served with the Content Security Policy the rules derive from its declaration under a fresh nonce, plus a `sandbox` directive opening exactly what the frame's declared capabilities open, so a page navigated to directly is never a first-party page of the origin. The entry page also gets a `<base>` naming its own directory and the SDK, inline under the nonce.

---

## Templates and Layout

A tincture starts from one of these templates (`cyfr new tincture <name> --template <template>`):

<!-- tincture:templates -->
| Template | Build | Entry |
|---|---|---|
| `vanilla` | — | `index.html` |
| `vite` | `vite` | `dist/index.html` |
| `react` | `vite` | `dist/index.html` |
<!-- /tincture:templates -->

A vanilla tincture is served as it is written. A built tincture (one whose manifest declares `tincture.build`) is compiled with `cyfr build compile t:local.<name>:<version>` on the Locus builds service, which replaces the version's `dist/` with the build's output; it serves only its entry's directory and `public/media/`, and the rest of the version — `package.json`, the lockfile, `src/` — is build input.

**The lockfile rule.** A tincture with a `package.json` ships its `package-lock.json` beside it, and a build installs exactly what the lockfile pins (`npm ci`), never what a registry answers on the day. A version without its lockfile is refused at publish and at build. After changing a dependency, regenerate the lockfile (`npm install --package-lock-only`). The build runs install scripts under an isolated account whose environment holds no credential, and keeps `dist/third-party-notices.json` for the runtime packages the bundle ships.

A built tincture's layout:

```
data/athanors/{athanor_id}/components/tinctures/local/my-game/0.1.0/
├── cyfr-manifest.json    ← type: "tincture", tincture.build.tool: "vite", tincture.entry: "dist/index.html"
├── package.json
├── package-lock.json     ← required beside package.json
├── vite.config.js        ← base: "./", build.outDir: "dist"
├── index.html            ← Vite's source entry
├── src/                  ← build input, never served
├── public/
│   └── media/
│       ├── icon.svg          ← the picker's icon (auto-discovered)
│       └── preview-1.svg     ← the focused card's previews (up to preview-6)
└── dist/                 ← the build's output, replaced whole by each build
    ├── index.html            ← served entry
    └── assets/               ← bundles, workers, WebAssembly, audio
```

`vite.config.js` keeps `base: "./"`, so every asset URL resolves relative to the entry wherever the version is served.

---

## Tincture Manifest

```json
{
  "name": "my-game",
  "type": "tincture",
  "version": "0.1.0",
  "publisher": "local",
  "description": "A physics toy",
  "tincture": {
    "entry": "dist/index.html",
    "build": {"tool": "vite"},
    "icon": "🎮",
    "tagline": "Knock the tower down",
    "window": {"width": 1280, "height": 720, "resizable": true},
    "frame": {"capabilities": ["pointer_lock", "fullscreen", "audio_autoplay"]},
    "actions": [],
    "streams": [],
    "cards": []
  },
  "dependencies": {
    "static": [
      {"ref": "c:local.save-slot", "reason": "Saves the player's progress"}
    ]
  }
}
```

### `tincture` Block

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `entry` | string | `"index.html"` | Entry page, relative to the version directory. A built tincture serves `"dist/index.html"`; relative URLs in the entry resolve from its own directory |
| `build` | object | — | `{"tool": "vite"}`: the version is built, and ships its lockfile. Omit for a vanilla tincture |
| `icon` | string | `"palette"` | Glyph fallback for the picker when no `public/media/icon.{svg,png}` exists: an emoji or a Lucide icon name |
| `tagline` | string | — | One line under the title in the picker |
| `public` | boolean | `false` | Metadata hint. Public access is an active public consent profile (`profile.publish`) |
| `window` | object | `{}` | Shell window hints: `width`, `height`, `resizable`, `singleton` |
| `connect` | string[] | `[]` | Bare external domains added to the page's `connect-src` over `https` (e.g. `["api.example.com"]`) |
| `media` | object | — | Overrides for the auto-discovered media; the `public/media/` convention needs none |
| `frame` | object | — | The frame's capabilities, placement and background flag (below) |
| `cards` | object[] | `[]` | Cards the shell may show for the tincture (below) |
| `streams` | object[] | `[]` | The streams the tincture may open (below) |
| `actions` | string[] | `[]` | The system actions the tincture may run, as `tool.action` |

### The declaration

`frame`, `cards`, `streams` and `actions` are the tincture's declaration. It is held to the rules at publish and read again at every open and every request: the declaration is the grant, and anything a frame asks for outside it is refused before it is dispatched. A version that declares more is consented to again.

<!-- tincture:declaration -->
| Block | Keys |
|---|---|
| `frame` | `background`, `capabilities`, `placement` |
| `frame.placement` | one of `float`, `desktop` |
| `cards[]` | `buttons`, `image`, `list`, `name`, `number`, `source`, `stream`, `title` |
| `cards[].buttons[]` | `action`, `args`, `label` |
| `streams[]` | `name`, `subject` |
| `actions[]` | an operation name, `tool.action` |
<!-- /tincture:declaration -->

- `frame.capabilities` names capabilities from the table below; `frame.background: true` keeps the frame active while hidden.
- A card's `number` and `list` name fields of its `source`'s answer, its `image` is a served image inside the version, and each button runs a declared action with fixed `args`. A card that shows a number or a list has a `source`: `component`, `operation` and `args` fixed at publish, an invoke of a component the tincture declares in `dependencies.static`, at most 4096 bytes of canonical JSON. A card without one is static.
- A stream's `name` is a stream a provider declares (two or more dotted names, such as `mcp_servers.changes`); its `subject` is a literal, `"*"` for any subject that stream's grammar admits, or absent for a stream that takes none.

### Frame capabilities

A frame gets nothing but scripts unless its declaration asks. Each capability adds exactly this to the frame the shell creates:

<!-- tincture:frame-capabilities -->
| Capability | `sandbox` adds | `allow` adds |
|---|---|---|
| `pointer_lock` | `allow-pointer-lock` | — |
| `fullscreen` | — | `fullscreen` |
| `gamepad` | — | `gamepad` |
| `audio_autoplay` | — | `autoplay` |
<!-- /tincture:frame-capabilities -->

A capability that is not in this table is refused at publish, and the shell refuses to open a frame whose declaration asks for one. The browser still decides each use: fullscreen and pointer lock need a gesture of the person's inside the frame.

### `dependencies.static`

The components the tincture may invoke. `cyfr.invoke` to a component that is not listed here is refused.

| Field | Type | Description |
|-------|------|-------------|
| `ref` | string | Component reference, versionless preferred (`f:local.stock-analysis`); pin `type:ns.name:version` only for reproducibility |
| `optional` | boolean | `false` = required for deployment |
| `reason` | string | Why the tincture needs it |

### Media convention

The picker finds a tincture's media at fixed paths, no manifest fields needed: `public/media/icon.svg` (or `.png`) and `public/media/preview-1.svg` … `preview-6.svg` (or `.png`). Previews are shown in a 16:9 stage, contained rather than cropped; SVG is preferred, and each file is best kept under ~500 KB. `cyfr new tincture` writes placeholders for both.

---

## Served Types

A version serves a file only of one of these types; publishing a version that serves any other is refused, naming the file.

<!-- tincture:served-types -->
| Extension | Served as |
|---|---|
| `.bin` | `application/octet-stream` |
| `.css` | `text/css` |
| `.data` | `application/octet-stream` |
| `.eot` | `application/vnd.ms-fontobject` |
| `.flac` | `audio/flac` |
| `.gif` | `image/gif` |
| `.glb` | `model/gltf-binary` |
| `.gltf` | `model/gltf+json` |
| `.html` | `text/html` |
| `.ico` | `image/x-icon` |
| `.jpeg` | `image/jpeg` |
| `.jpg` | `image/jpeg` |
| `.js` | `text/javascript` |
| `.json` | `application/json` |
| `.ktx2` | `image/ktx2` |
| `.m4a` | `audio/mp4` |
| `.map` | `application/json` |
| `.mjs` | `text/javascript` |
| `.mp3` | `audio/mpeg` |
| `.oga` | `audio/ogg` |
| `.ogg` | `audio/ogg` |
| `.opus` | `audio/ogg` |
| `.otf` | `font/otf` |
| `.pck` | `application/octet-stream` |
| `.png` | `image/png` |
| `.svg` | `image/svg+xml` |
| `.ttf` | `font/ttf` |
| `.wasm` | `application/wasm` |
| `.wav` | `audio/wav` |
| `.woff` | `font/woff` |
| `.woff2` | `font/woff2` |
<!-- /tincture:served-types -->

`cyfr-manifest.json`, `schema.sql`, `data.db` and dotfiles are never served. A version's decompressed size is stated at publish and refused over the registry's ceiling (256 MiB by default).

---

## The Cyfr SDK

The SDK is injected into the entry page's `<head>` under the page's nonce, so `window.cyfr` exists before the page's own scripts run. Do not load it yourself.

<!-- tincture:sdk -->
| Call | Carried by |
|---|---|
| `cyfr.action(name, args)` | `POST /_f/v1/action` |
| `cyfr.invoke(ref, operation, args)` | `POST /_f/v1/invoke` |
| `cyfr.stream(name, subject, onEvent)` | `POST /_f/v1/stream` |
| `cyfr.open(ref)` | the shell's port, `open` |
| `cyfr.close()` | the shell's port, `close` |
| `cyfr.title(title)` | the shell's port, `title` |
| `cyfr.ready()` | the shell's port, `ready` |
| `cyfr.credential(name)` | the shell's port, `credential` |
<!-- /tincture:sdk -->

- **`cyfr.invoke(ref, operation, args)`** runs a component the tincture declares in `dependencies.static`. The component runs with the input `{"operation": …, "params": …}` — `operation` the name given, `params` the `args` object — and the promise resolves with `{status, output, execution_id, duration_ms}`.
- **`cyfr.action(name, args)`** runs a system action the declaration's `actions` lists (`"tool.action"`), with `args`, and resolves with its result.
- **`cyfr.stream(name, subject, onEvent)`** opens a stream the declaration's `streams` lists, with a literal subject or `null` for one that takes none. It resolves, once the stream is open, with a handle: `handle.close()` ends it and `handle.closed` settles when it ends, whether the grant's deadline passed, the endpoint closed it or `close()` was called. `onEvent` is called with `{id, event, data}` per event: `id` the sequence number where the topic carries one, `event` the stream's name, `data` the payload projected to the grant's fields. A stream the endpoint closes for a reason the frame should know ends with an event named `refusal`. A reconnect is a new `cyfr.stream` call, admitted again.
- **`cyfr.open(ref)`** asks the shell to open another tincture it lists; **`cyfr.close()`** closes this frame; **`cyfr.title(title)`** sets its title (at most 120 characters); **`cyfr.ready()`** tells the shell the tincture has loaded. No verb places, sizes or raises a frame: which frame is shown is the shell's and the person's. Shell verbs made before the handshake wait for it; outside a frame they do nothing.
- **`cyfr.credential(name)`** asks the person for a secret through the shell's own prompt, to be stored in the vault as the entry `name`; see [Secrets](#secrets). It resolves with `{saved}` once the prompt closes.
- `cyfr.frame` is the frame id the shell handed this frame (`null` before the handshake), and `cyfr.public` the public tincture a top-level page names itself as (`null` in a frame).

A refusal rejects with a `CyfrError`: `message` is the sentence, `code` the refusal's class (`unauthenticated`, `forbidden`, `not_found`, `rate_limited`, `consent_required`, `invalid_argument`, `unavailable`, …) and `stage` whether it was refused at `admission` or during `execution`. A frame that has no credential yet waits up to 30 seconds for the shell's handshake and then rejects with `no_frame`.

**Public mode.** A public tincture's page opened at its address, outside any frame, has no shell and no credential: the SDK names the tincture from the page's path as `public: {athanor, publisher, name}` in each request and sends no bearer. The endpoint admits such a request only for a tincture that is public, under its public profile; it opens no stream. Any other top-level page — a private `/_s/` page among them — answers `no_frame`.

```javascript
// src/main.js
cyfr.ready();

const saved = await cyfr.invoke("c:local.save-slot", "save", { level: 3, score: 1200 });
console.log(saved.status, saved.output);

const feed = await cyfr.stream("mcp_servers.changes", null, ({ event, data }) => render(event, data));
// …later
feed.close();
```

### The wire

The SDK is the only client of three routes, each a `POST` of a JSON body carrying `v` (the wire version) with the frame credential as `Authorization: Bearer <credential>` — never in a URL or a body:

<!-- tincture:wire-routes -->
| Request | Route |
|---|---|
| `action` | `POST /_f/v1/action` |
| `invoke` | `POST /_f/v1/invoke` |
| `stream_open` | `POST /_f/v1/stream` |
<!-- /tincture:wire-routes -->

An `invoke` or `action` answers `{"v", "ok": true, "result"}`, a refusal `{"v", "ok": false, "error": {"class", "message", "stage"}}`; an admitted `stream_open` answers `text/event-stream`. These routes carry no session cookie and no CSRF token: the bearer is the only credential, and the `null` origin of a sandboxed frame is answered on these routes alone. `Prima.TinctureWire` defines the shapes and `tests/fixtures/tincture_wire.json` holds one of each.

---

## What the Frame May Do

The frame's document is sandboxed without `allow-same-origin`, so its origin is `null` to every browser, and its policy is derived from its declaration:

| Directive | Value | So the tincture |
|---|---|---|
| `script-src` | `'self'`, the page's nonce, `'wasm-unsafe-eval'` | loads scripts and module scripts from the origin and compiles WebAssembly; no inline script but the SDK, no `eval` |
| `worker-src` | `'self' blob:` | runs workers from its own files or from `blob:` URLs (inline workers) |
| `connect-src` | the endpoint's origin and `https://` each `tincture.connect` domain | fetches only its own files, the endpoint and the domains it declares |
| `img-src`, `media-src`, `font-src` | the origin, plus `data:` and `blob:` where they apply | decodes images, audio and fonts it ships or generates |
| `style-src` | `'self' 'unsafe-inline'` | uses stylesheets and inline styles |
| `form-action` | `'none'` | submits no form (the sandbox has no `allow-forms` either) |
| `object-src`, `base-uri`, `frame-ancestors` | `'none'`, `'self'`, the shell | embeds no plugin, and is framed by the shell alone |

It has no cookies and no `localStorage` or `sessionStorage` (the opaque origin has none), no access to `window.top`, `window.opener` or the shell's document, no popups and no top-level navigation. A frame may navigate itself; that navigation carries no `Referer` and nothing the frame was not given, and ends its handshake. Keep all JavaScript in files — an inline `<script>` of your own is blocked without an error.

---

## Game Patterns

A game is a tincture like any other; these patterns keep one smooth inside a frame and inside its grant:

- **A fixed timestep.** Step the simulation at a fixed rate and interpolate rendering between steps, so physics does not depend on the display's refresh rate.
- **Objects pooled.** Allocate bodies, meshes, projectiles and particles up front and reuse them; allocation in the frame loop is garbage collection in the frame loop.
- **Particles on the GPU.** Animate particles in a shader (a points material or instanced mesh driven by time uniforms), not by writing positions from JavaScript each frame.
- **A fixed set of lights.** Choose the lights once; adding or removing lights recompiles shaders.
- **Physics off the main thread.** Step a WebAssembly physics engine (Rapier, Box2D) in a worker — an inline `blob:` worker is allowed — and post transforms back.
- **Textures compressed.** Ship KTX2 (`.ktx2`) textures and glTF/GLB models; they are served types.
- **Audio decoded once.** Decode each sound into an `AudioBuffer` at load and play buffers; declare `audio_autoplay` if sound starts before a gesture.
- **Refused:** `eval` and `new Function`; imports from a remote URL (bundle every dependency, pinned by the lockfile); secrets of any kind in the frame; persistence outside components (save through a component the tincture declares); an invocation per frame — invoke on an event such as a save or a level's end, never from the render loop.

Declare `pointer_lock`, `fullscreen`, `gamepad` and `audio_autoplay` only as the game uses them; request fullscreen and pointer lock from a click or key press inside the frame.

---

## Limits

| Limit | Setting | What happens |
|-------|---------|-------------|
| Requests per frame | `frame_invocation_max` per `frame_invocation_window_ms` (120 per minute by default), charged on every invoke, action and stream open; a public page is charged per address and tincture | refused `rate_limited` with its retry seconds |
| Open streams per frame | `frame_stream_max_concurrent` (8) | refused `rate_limited` until one closes |
| Frame credential lifetime | `frame_credential_deadline_s` (one hour), capped by the session's own | refused; open the tincture again |
| Asset credential window | `asset_credential_window_s` (one hour) | the shell mints the next one |
| Version size | the registry's decompressed ceiling (256 MiB) | refused at publish |
| Handshake wait | 30 seconds | the SDK rejects with `no_frame` |

Each setting is a platform setting (see the [Configuration Guide](configuration-guide.md)). The consent profile the tincture runs under adds its own rate and budget.

---

## Security Model

- **The declaration is the grant.** A frame reaches only the components in `dependencies.static`, the actions in `actions` and the streams in `streams`; everything else is refused before dispatch, and every request is recorded as the gate's decision.
- **One credential per open.** The frame credential is minted for one frame of one person, held to that person's session or key at every request, suspended with its frame and revoked when it closes. A copy of it carries exactly the frame's authority for its remaining life and nothing wider.
- **Files by path.** A private version's files open only under an asset credential that names that version's digest; a credential leaked in a URL opens that version's bytes for its window and nothing more.
- **No secrets in the frame.** Component credentials are resolved server-side and outputs are secret-masked before they reach the browser.
- **Invoke formulas, not raw catalysts.** Anyone holding the frame can call any component the tincture declares, bypassing its interface; declare a formula that validates input and enforces the business rules, and let it call the catalyst.

```
AVOID:
  Tincture → cyfr.invoke("c:local.stripe-charge", "charge", input)

RECOMMENDED:
  Tincture → cyfr.invoke("f:local.purchase-flow", "buy", input)
                              ↓
                  the formula validates, then calls c:local.stripe-charge
```

---

## Error Reference

| `code` | When | Fix |
|--------|------|-----|
| `unauthenticated` (`no_frame`) | the page is not a frame the shell opened, or the handshake never came | open the tincture from the shell, or publish it and use its public address |
| `forbidden` (`frame_suspended`) | the frame is hidden and does not declare `frame.background` | act when shown, or declare `background` |
| `forbidden` (`frame_moved`) | the version or its owner profile's grant changed since the frame opened | open the tincture again |
| `forbidden` (undeclared) | the component, action or stream is not in the declaration | declare it and publish a new version |
| `consent_required` | the tincture has no active profile for the route | grant its owner profile, or publish its public one |
| `rate_limited` | the frame's request rate or open streams are over their bound | wait the seconds it names; invoke on events, not per frame |
| `invalid_argument` | a request that does not match the wire | pass a reference, an operation name and an object |
| `unavailable` | the server could not answer | retry |
| Blank page | an inline `<script>` blocked by the policy | move the script to a file |
| 404 on a file | a type that is not served, a reserved file, or another version's path | ship a served type under the version |

---

## Before Committing

- [ ] `cyfr-manifest.json` has `type: "tincture"` and its declaration names every capability, component, action and stream the tincture uses — and nothing more
- [ ] Every served file is a served type; no inline `<script>` of your own
- [ ] `cyfr.ready()` is called from the tincture's script
- [ ] A `package.json` ships with its `package-lock.json`, regenerated after every dependency change
- [ ] Built tinctures: `vite.config.js` keeps `base: "./"`, and `cyfr build compile t:local.<name>:<version>` succeeds before registering
- [ ] No secret, key or token in any file of the version
- [ ] Public tinctures: the page works at its address with no session

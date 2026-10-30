# Tincture Reference

Build, test, and deploy tinctures for CYFR. A tincture is a browser frontend — HTML, JavaScript, CSS and whatever assets it ships, WebAssembly and audio included — that the Prism shell opens in a sandboxed frame. It reaches the server only through the Cyfr SDK (`window.cyfr`): it invokes the components it declares, runs the system actions it declares and opens the streams it declares, and CYFR resolves credentials, consent and execution server-side. A canvas's only data requests open the streams it declares ([The Canvas](#the-canvas)). A tincture never holds an API key, a session or a secret.

The lists in this guide — served types, frame capabilities, templates, the declaration grammar, the wire's routes and the SDK's calls — are the frame's rules (`Compendium.Tincture.Rules`) and the wire (`Prima.TinctureWire`) as they stand; the docs-drift test fails when one of them differs.

---

## How a Frame Opens

The shell is the one place a tincture's frame is created. Launching a tincture:

1. The shell reads the version's declaration and renders the frame's `sandbox` and `allow` attributes from the rules for the capabilities it declares: `allow-scripts` always, every other token or permission only for a capability declared, and never `allow-same-origin`, `allow-forms`, `allow-popups` or any `allow-top-navigation`. A declaration the rules refuse opens nothing.
2. The frame's page is a private tincture's entry under an **asset credential** in its path, or a public tincture's public address. No URL carries anything that opens more than the version's own files.
3. The shell mints a **frame credential** for this open, bound to the person, the tincture version and its release digest, the grant revision of the tincture's owner profile and a fresh frame id.
4. On the frame's first load the shell posts it one handshake carrying a `MessagePort` and the frame id, and sends the frame credential over that port only. The SDK accepts the handshake only from its parent window, and only once.

A canvas opens the same way, with three differences: its page is served at `/_c/v1/` and loads the SDK from CYFR's own path ([The canvas page](#the-canvas-page)); its handshake also names its data path and the streams it declares; and the shell acts only on its `ready`, `failed`, `open` and `press`, drops its other verbs, and sends it `installed`, `posture`, `covered` and `state` over the port ([What a canvas may do](#what-a-canvas-may-do)).

From then on the SDK sends data requests to the endpoint with the frame credential as a bearer, and the shell verbs (`open`, `close`, `title`, `ready`, `credential`) over the port. The shell listens to no window message; anything arriving on the port that is not a shell verb for that frame is dropped. A reload or a navigation inside the frame gets no second handshake: the frame is spent until the person opens the tincture again.

A frame hidden behind another is **suspended** unless it declares `frame.background`, and resumed when shown: a suspended frame's requests are refused (`frame_suspended`). A resume that fails revokes the frame's credential and the frame shows the refusal in place of its page. Closing the frame, the `close` verb, the registry no longer listing the tincture and the end of the shell's session each revoke its credential. A frame credential is also refused once the tincture's version or its owner profile's grant moved since the open (`frame_moved`): open it again.

### Private and Public

A tincture is private unless it has an active public consent profile. Publish one with `profile.publish` (the proof-bound consent walk) and unpublish by revoking it with `profile.revoke`; `tincture_visibility.get` reports the current answer. The manifest's `tincture.public` is a metadata hint only. A canvas is never public: it is the person's own data page, so no public profile is staged for one and the public route serves none. `profile.publish` refuses to stage one (`invalid_argument`), and its address answers not found, as a private tincture's does.

| | Private | Public |
|---|---|---|
| **Its files** | `/_s/<asset credential>/<publisher>/<name>/<version>/<file>`, only under a credential the shell minted for the person | `/t/<athanor>/<publisher>/<name>` and the files under it, to anyone |
| **Opened by** | the shell, for a member of its athanor | the shell, or anyone at its address |
| **Data requests** | the frame credential as a bearer | in the shell, the frame credential; at its address, the page names itself as `public` and sends no bearer |
| **Runs under** | the tincture's owner profile | the owner profile in the shell; its public profile at its address |

---

## The Canvas

The shell — **Apps** in the console's drawer (**Tinctures** in `dev` mode), at `/a/<athanor>/tinctures` — shows the person's canvases and the tinctures opened over them. A **canvas** is a tincture whose `frame.placement` is `canvas`: the person's own page, written in HTML, CSS and JavaScript like any tincture, that shows what it reads.

The person's **layout** (`layout.get`, `layout.edit`) is a version-3 document: their canvases in order, at most eight, each with an `id`, the canvas tincture it runs (each canvas its own) and, per posture — `hand` under 768 CSS pixels wide, `desk` otherwise — the tinctures placed over it. A person has one layout in each athanor. A posture a canvas does not name places nothing. The layout names tinctures, modes and places and nothing else, so editing it can only arrange, and no canvas edits it. A person who never arranged one has the shipped layout: one canvas, `home`, running the shipped `tincture:local.canvas`, which shows their apps, their recent runs, their schedules and the last schedule runs. A layout is published only through the `layout` tool's `edit`. The CLI, the API and a device paired with the person call it for the person, and so does the assistant, whose shipped policy asks the person first. No tincture declares `layout.edit`, and no component but an agent that names it exactly is granted it. Every shell the person has open reads the layout again when an edit is announced, or on its next posture change or reconnect when the announcement does not go out; no shell, canvas or safe mode writes it.

The canvas the browser shows is the **visible canvas**, the layout's first when the shell opens. With more than one canvas, the person moves between them with the switcher the shell draws, with `Ctrl+Alt+ArrowLeft` and `Ctrl+Alt+ArrowRight`, or with a horizontal swipe on the 16-pixel strip the shell keeps along the bottom edge; nothing wraps at either end. Switching is the shell's alone: no canvas has a verb for it, so a broken canvas cannot hold the screen. Only the visible canvas reads and acts — a switch freezes the canvas it leaves, whatever it declares, with its apps and floating tinctures unless they hold the background grant — and a tincture belongs to the canvas it was opened on. A layout with no canvas, a canvas whose tincture is not installed, or a layout the shell cannot read runs no canvas, and the shell draws its picker instead; launching a tincture from the picker opens it full, above everything.

### Sizes and placements

A tincture's `frame.placement` says where it may stand: with none it opens as an app, `float` lets it also float over a canvas, and `canvas` makes it a canvas. Over each canvas, per posture, the layout places apps, each in one of two modes, and floating tinctures:

| Placement | What is drawn |
|---|---|
| a `column` app | the tincture's own frame in a column beside the canvas, by its `order`, opened with the canvas: side by side against the right edge on the desk, one above another across the width in the hand |
| a `full` app | the tincture's own frame over the whole screen while it is shown, opened when the canvas opens it |
| a floating tincture | the tincture's own frame at its `position` over the canvas (`x` and `y` in hundredths of a percent of the viewport), opened with the canvas, only for a tincture whose declaration names `frame.placement: "float"` |

A tincture the canvas opens that the layout does not place opens full in the hand and as the next column on the desk; nothing is written to the layout. A floating entry naming a tincture nobody installed draws a placeholder and opens nothing.

### The canvas declaration

A tincture is a canvas when it names `frame.placement: "canvas"`. It names its page as `tincture.entry`, on one of two templates: `vanilla`, `index.html` with no build, or `react`, `dist/index.html` built by `vite`, with `package-lock.json` beside `package.json`; its npm packages are bundled at build and never loaded from another origin. A canvas changes nothing in CYFR, so it declares no `tincture.connect` origin, `caps.egress`, component dependency (static or dynamic), frame capability, `frame.background` or action. It declares the streams it reads, each one a stream that declares a shape, naming each feed it reads ([Streams and feeds](#streams-and-feeds)). Its entry is among the version's files, and of its `.html` files only the entry is ever a page.

```json
{
  "type": "tincture",
  "name": "markets",
  "version": "0.1.0",
  "tincture": {
    "entry": "index.html",
    "frame": {"placement": "canvas"},
    "streams": [{"name": "runs.changes"}, {"name": "feed.results", "subject": "btc"}]
  }
}
```

### The canvas page

The shell frames a canvas at `GET /_c/v1/<asset credential>/<frame id>`, one page for one open, never cached. It is the version's entry document with two things first in its `<head>`: a `<base>` naming the version's served files, so the page's relative URLs (`app.js` beside a vanilla `index.html`, `./assets/…` from Vite's `base: "./"`) load its own files, and then the SDK, loaded by `<script src>` from CYFR's one fixed path. CYFR's `<base>` comes first, so one the page writes is ignored. Every refusal is a 404 with an empty body — an asset credential that does not stand, a frame id naming no standing frame of the credential's person, athanor and version, a release digest that moved, or a placement other than `canvas` — and a store that cannot say answers 503. The path carries the asset credential, so no proxy may log `/_c/v1/` paths either.

The page's policy (`Compendium.Tincture.Rules.canvas_page_csp/1` holds its directives) admits:

- scripts from the version's files and the SDK's path, and no inline script at all, so keep every script in a file;
- styles from the version's files and inline styles, so an `@import` too reaches only the version's files;
- images, fonts and media from the version's files alone, and an image also from a `data:` or `blob:` URL;
- workers from the version's files or `blob:` URLs, under this same policy;
- requests to the version's files and the open's own data path, `/_f/v1/o/<frame id>/`, and nowhere else;
- no frame, plugin or form of its own, and a sandbox of `allow-scripts` alone: no popup and no top-level navigation.

Nothing on those paths redirects.

### What a canvas may do

On a canvas's page the SDK carries these calls:

- **`cyfr.stream(name, subject, onEvent)`** opens a stream the version declares, as on any tincture, on the canvas's own data path, `POST /_f/v1/o/<frame id>/stream`; a name and subject the version does not declare is refused.
- **`cyfr.on(event, handler)`** calls `handler` with each value the shell sends of `installed` (the installed tinctures that are not canvases, as `[{ref, name, icon, open}]`), `posture` (`hand` or `desk`), `covered` (the rectangles of the canvas the tinctures open over it cover) or `state` (`live` or `frozen`).
- **`cyfr.open(ref)`** opens an installed tincture where the layout places it ([Sizes and placements](#sizes-and-placements)); one `installed` does not list is dropped.
- **`cyfr.press(binding, action)`** presses an action of a feed the canvas declares, `binding` the binding id of that feed's latest result.
- **`cyfr.ready()`** tells the shell the canvas has drawn.

<!-- tincture:canvas -->
| Call | Carried by |
|---|---|
| `cyfr.press(binding, action)` | the shell's port, `press` |
| `cyfr.grant(ref)` | the shell's port, `grant` |
| `cyfr.on("installed", handler)` | the shell's port, `installed`: each tincture's `icon`, `name`, `open`, `ref` |
<!-- /tincture:canvas -->

The shell drops a canvas's `close`, `title` and `credential`, and the shared routes refuse its credential, so `cyfr.invoke` and `cyfr.action` reject: a canvas writes nothing and invokes no component.

The shell forwards a canvas's `open` or `press` only within moments of the person's own input, never from a script on its own: several sent within those moments are each forwarded, and one sent otherwise is dropped. The shell sends a press to `feed.press` under the person's session, only from the visible, live canvas whose served version declares that feed; a binding removed or rebound since is refused, so a press made for an earlier binding never presses the new one.

Every label a canvas shows, on a control or anywhere else, is the canvas's own text: CYFR does not check that a control says what it does.

An error the page does not catch — a throw, or a rejection nothing handles, such as a refused `cyfr.stream` without a `catch` — fails the canvas, before `cyfr.ready()` or after it, and the shell enters safe mode (`crashed`), which offers the kept version. The browser's benign ResizeObserver loop messages are ignored.

A canvas holds a window, so what it reads can leave the browser like any app's: through a message to another frame, which no page policy closes, or a peer connection, which its policy closes only in Chromium. It cannot change anything in CYFR: its credential reaches only its own streams, and the shell acts on its opens and presses only within moments of the person's own input. Only the person's own canvases open: a canvas from a publisher other than `local` puts the screen into safe mode instead.

### Streams and feeds

A canvas reads only the streams it declares, and only a stream whose provider declares a shape for it; `canvas.catalog` lists them with their shapes. Such a stream is a canvas's alone: publish refuses one in any other declaration, and an open from any other tincture's frame is refused `forbidden` (`canvas_stream`). Each is handed its current state first, each item marked `refresh: true`, and then its live events; an event that races the current state may arrive twice, so a canvas takes a feed's result once per `revision`, a run's change once per `execution_id` and `kind`, a schedule run once per `occurrence_id` and `kind`, and a schedule's change as that schedule's latest state.

| Stream | Subject | What a canvas reads |
|---|---|---|
| `runs.changes` | — | each run's `kind`, `execution_id`, `parent_execution_id`, `reference`, `component_type`, `duration_ms` and `error`, after the athanor's 20 newest runs |
| `schedules.changes` | — | each schedule's `kind` (`changed` or `removed`), `schedule_id`, `name`, `reference`, `cron_expression`, `status`, `next_run_at`, `last_run_at`, `run_count` and `error_count`, after every live schedule of the athanor as `changed` |
| `schedule_runs.changes` | — | each run of a schedule as its `kind` (`fired` or `failed`), `schedule_id`, `occurrence_id`, `execution_id`, `scheduled_for` and `reason`, after the athanor's 20 newest occurrences of schedules; a feed's fire is not a schedule run |
| `feed.results` | a feed's name | each accepted result of that feed as its `binding` id, `feed`, `revision`, `at`, `result`, `label` and `actions`, after its last accepted result |

A canvas names every feed it reads: one `feed.results` entry per feed, the feed's name its literal subject — never `"*"` and never none — and each name once. A feed is bound with the `feed` tool, by the person or by the assistant with the person's approval (the [Integration Guide](integration-guide.md) lists it); a canvas's code has no verb that binds, changes or refreshes one. From a canvas, a feed's action runs only on a press the shell forwards within moments of the person's own input, never from a script on its own, and sends to `feed.press`; the CLI and the API reach `feed.press` as they reach any external operation, and no chain does. The canvas's data path admits only that open's credential and has no invoke and no action route. Each stream a canvas reads is its own open, so `frame_stream_max_concurrent` bounds how many it reads at once.

### Validation and the kept version

A canvas changes only as a new version: `canvas.write` creates the next version whole, a version's files are never replaced, and the publish check holds each version as it does any tincture's. When a browser is to show a canvas whose newest installed version is neither its working version, its kept version nor its last failed one, the shell first validates that version in a bounded mode. It opens the version once in a hidden, inert frame under a **validation credential**, which carries no live authority: each declared stream the candidate opens is answered once from a fixture of its shape — for a feed, of the result shape of the feed the athanor binds under that name, and nothing for a name it does not bind — and then ends, admitting nothing. From that frame the shell acts only on `ready` and `failed`. The candidate must call `cyfr.ready()` within ten seconds of its frame's open. The shell tears the frame down on `ready`, the deadline, a failure or the frame's death, and reports the outcome — `ready`, `not_ready` or `died` — to `canvas.activate`, which spends the credential. Only `ready` activates: the version becomes the working one once its grant is current (the grant prompt asks otherwise, and the version is validated again after it), and the version it replaces is kept. Any other outcome records the failure. Once a validation ends the browser compares again: a newer version written meanwhile that needs validating is validated in its turn, each such version once, and otherwise the browser opens the working version, or enters safe mode when there is none. A version written while no browser shows its canvas waits for one. The kept version is the way back, restored by `canvas.restore` under today's grant, so a kept version is never kept permission.

### Hidden, frozen and background frames

The frame the person looks at is live. With a full frame shown, every other frame — the canvas among them — is hidden, as is every canvas the browser does not show, with its apps and floating tinctures, and a hidden frame without `frame.background: true` is frozen: its credential is suspended before its bridge is told, its element is inert, and its requests are refused as `frame_suspended` until it is shown again; a validation's frame is hidden but never frozen, since its credential is never suspended. A frame that declares the background grant keeps running hidden. A hidden canvas is frozen whatever it declares, so it reads nothing and acts on nothing: it hears `state` `frozen`, its streams close with its suspended credential, a stream it asks for sends nothing until it is shown and opens then, and its opens and presses are dropped. Its JavaScript may keep running until the browser discards the frame, and what it reports of itself still counts: a hidden canvas that calls `cyfr.ready()` is ready, and one that fails is shown as safe mode (`crashed`) once it is shown. Shown again, it hears `state` `live` and reads again, and a stream it opens again refreshes first. A frame never raises itself: no verb places, sizes or raises a frame.

### Safe mode

Safe mode is the way back, outside every canvas. The shell enters it for one of four reasons: the visible canvas has not sent `ready` within ten seconds of being shown, or cannot be opened (`not_ready`; one refused for want of the person's grant shows its refusal and offers the grant prompt instead); the live canvas fails on an error it did not catch, or its frame goes away while it is shown, or a canvas that failed while hidden is shown (`crashed`); a new version failed its validation and the canvas has no working version (`not_validated`); or the person asks — the shell's **Safe mode** button, or Ctrl+Alt+S on the shell's page, which a frame never hears (`requested`). A hidden canvas owes no `ready`: the ten seconds run from its frame's open for a canvas that opens shown, and otherwise from the moment it is shown, and a canvas ready before it was hidden stays ready. In safe mode every frame is discarded with its credential, and the system layer offers the ways out: try the canvas again as it now stands; go back to its kept version, while it keeps one, which `canvas.restore` makes the working version again under today's grant; or show the shipped canvas in this browser, while a canvas is visible, until the shell ends or the layout changes, writing no layout and no versions document. Safe mode runs no tincture at all, and the assistant's panel stays as it was.

### Secrets

A frame never asks for a secret and never holds one. **`cyfr.credential(name)`** asks the shell to prompt the person for a value to store in the vault as the entry `name`; the shell honours it only for a live, visible frame whose declaration lists `vault.create`, and drops it otherwise. The shell's own prompt asks for the value, the hosts it may be sent to and whether components may read it; nothing is prefilled, and unless the person discloses it the entry is attach-only: CYFR attaches its value to requests bound for its destination, its value is never handed to a component, and a component asking for it is refused. The value goes to the vault; the frame is told only that the prompt closed and whether an entry was saved (`{saved: true | false}`), never the value and never why nothing was saved. A frame cannot change or remove a vault entry: renaming, rotating, rebinding, revoking, deleting and OAuth authorization need an interactive session, and are the console's vault page's. The shipped vault tincture lists entries through `vault.status` and adds them through `cyfr.credential`.

A tincture may satisfy a backing component's need with public configuration
in its manifest's `provides`: the exact dependency reference from
`dependencies.static`, then the need name, then a `destination` and
string `values` map. The dependency must declare a credential need with
an `attach` rule. Each provided entry's value names and string values
together span at most 4 KiB; its destination is validated separately.
The grant preview shows the destination and that the publisher provides
the values, so it asks for no vault entry for that need. These values
are public, attached and read alike; changing them or their destination
asks for consent again. Keep private keys in the vault.

---

## Addresses, Credentials and Headers

A public tincture is served at its address, `/t/<athanor>/<publisher>/<name>` (the athanor segment is `@<namespace>` for a person's athanor, the group's slug for a group's), with its files under it. The address follows the tincture's latest version. A canvas is never public: it is the person's own data page, so no public profile is staged for one and the public route serves none.

A private tincture version's files are served only at `/_s/<credential>/<publisher>/<name>/<version>/<file>`. The asset credential is signed, opaque and URL-safe; it names the person, the version's release digest and a window (`asset_credential_window_s`), carries no secret, and is verified against its source's standing at every request — a session that ended, a key that was revoked, a person denied or an athanor archived refuses the next fetch. It stays one credential for one person and one version for the window, so a browser's cache holds across opens, and it opens nothing but that version's files: another version's path under it is not found.

Every tincture response carries:

- `Referrer-Policy: no-referrer`, so no tincture URL — a private one carries its asset credential — leaves in a `Referer`;
- `X-Content-Type-Options: nosniff` and `Access-Control-Allow-Origin: *` (the frame's origin is `null`; what authorizes a read is the URL, never the requesting origin);
- `Cache-Control: public, max-age=3600` for a public tincture's files, `no-cache` for its address, and `private, max-age=<n>` for a private version's files, `n` never above the seconds the credential has left;
- `Content-Encoding: gzip`, for a client that accepts it, on text, scripts, JSON, SVG, glTF and WebAssembly.

A path under `/_s/` is a credential. **No proxy may log `/_s/` paths.** The server redacts the credential segment from the request path before any log line, span or error report names it; the shipped `Caddyfile` keeps no access log, and a proxy placed in front of CYFR must keep none for these paths either.

Every HTML page of a version is served with the Content Security Policy the rules derive from its declaration under a fresh nonce, plus a `sandbox` directive opening exactly what the frame's declared capabilities open, so a page navigated to directly is never a first-party page of the origin. The entry page also gets a `<base>` naming its own directory and the SDK, inline under the nonce. An HTML file of a canvas version is not found here: its entry is served only as its page ([The canvas page](#the-canvas-page)).

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
    "frame": {"capabilities": ["pointer_lock", "fullscreen", "audio_autoplay"]},
    "actions": [],
    "streams": []
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
| `connect` | string[] | `[]` | Bare external domains added to the page's `connect-src` over `https` (e.g. `["api.example.com"]`). Each origin is an exit of the frame: what the frame reads may reach it only through a flow your `caps.flows` declares to that origin as spelled here, from each source class the frame's reads may carry. The consent shows each origin with its flows, and a data request whose classes have no flow to every origin is refused |
| `media` | object | — | Overrides for the auto-discovered media; the `public/media/` convention needs none |
| `frame` | object | — | The frame's capabilities, placement and background flag (below) |
| `streams` | object[] | `[]` | The streams the tincture may open (below) |
| `actions` | string[] | `[]` | The system actions the tincture may run, as `tool.action` |

### The declaration

`frame`, `streams` and `actions` are the tincture's declaration. It is held to the rules at publish and read again at every open and every request, and it is never the grant: a version opens only under its owner profile's grant whose shape names what the version declares, so a tincture with no grant, or a version that declares more than its grant names, opens nothing and the shell asks the person for the grant instead. Anything a frame asks for outside its declaration is refused before it is dispatched.

<!-- tincture:declaration -->
| Block | Keys |
|---|---|
| `frame` | `background`, `capabilities`, `placement`, `size` |
| `frame.placement` | one of `canvas` |
| `frame.size` | `aspect`, `min`, `preferred`, `tile`: `min` and `preferred` each `w` and `h`, 100 to 4000 CSS pixels; `aspect` `w` and `h`, whole numbers 1 to 100; `tile` one of `left`, `right` |
| `streams[]` | `name`, `subject` |
| `actions[]` | an operation name, `tool.action` |
<!-- /tincture:declaration -->

- `frame.capabilities` names capabilities from the table below; `frame.background: true` keeps the frame active while hidden.
- A stream's `name` is a stream a provider declares (two or more dotted names, such as `mcp_servers.changes`); its `subject` is a literal, `"*"` for any subject that stream's grammar admits, or absent for a stream that takes none.
- A stream that declares a shape (`runs.changes`, `schedules.changes`, `schedule_runs.changes`, `feed.results`, each one `canvas.catalog` lists) is a canvas's alone: publish refuses it in any other declaration, whatever its subject, and an open from any other tincture's frame is refused `forbidden` (`canvas_stream`) ([Streams and feeds](#streams-and-feeds)).
- An action is an operation name, `tool.action`. No tincture declares `feed.bind`, `feed.remove` or `feed.press`, which are the person's, or `layout.edit`: the layout is the person's arrangement, and no tincture writes it ([The Canvas](#the-canvas)). Nor does any declare `schedule.create` or `schedule.update`: no tincture schedules itself or anything else.

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

`cyfr-manifest.json` and dotfiles are never served. A version's decompressed size is stated at publish and refused over the registry's ceiling (256 MiB by default).

---

## The Cyfr SDK

The SDK is injected into the entry page's `<head>` under the page's nonce (on a canvas's page, loaded from CYFR's own path), so `window.cyfr` exists before the page's own scripts run. Do not load it yourself.

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
- On a canvas's page, **`cyfr.on(event, handler)`** and **`cyfr.press(binding, action)`** carry what the shell sends the canvas and presses of its feeds' actions, forwarded only within moments of the person's own input ([What a canvas may do](#what-a-canvas-may-do)).
- `cyfr.frame` is the frame id the shell handed this frame (`null` before the handshake), and `cyfr.public` the public tincture a top-level page names itself as (`null` in a frame).

A refusal rejects with a `CyfrError`: `message` is the sentence, `code` the refusal's class (`unauthenticated`, `forbidden`, `not_found`, `rate_limited`, `consent_required`, `invalid_argument`, `unavailable`, …) and `stage` whether it was refused at `admission` or during `execution`. A `cyfr.stream` open that got no answer — the endpoint could not be reached, the connection broke or timed out, or it answered a server error — rejects as `unavailable` with no `stage`, whatever the error said, and may open if tried again later; opened again after any other refusal, it meets that refusal until something changes. A frame that has no credential yet waits up to 30 seconds for the shell's handshake and then rejects with `no_frame`.

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

An `invoke` or `action` answers `{"v", "ok": true, "result"}`, a refusal `{"v", "ok": false, "error": {"class", "message", "stage"}}`; an admitted `stream_open` answers `text/event-stream`. These routes carry no session cookie and no CSRF token: the bearer is the only credential, and the `null` origin of a sandboxed frame is answered on these routes alone. `Prima.TinctureWire` defines the shapes and `tests/fixtures/tincture_wire.json` holds one of each. A canvas's SDK sends its one request, `stream_open`, to the canvas's own data path, `POST /_f/v1/o/<frame id>/stream`, instead ([What a canvas may do](#what-a-canvas-may-do)).

---

## What the Frame May Do

The frame's document is sandboxed without `allow-same-origin`, so its origin is `null` to every browser, and its policy is derived from its declaration as this table gives for every tincture but a canvas, whose page's policy [The canvas page](#the-canvas-page) gives:

| Directive | Value | So the tincture |
|---|---|---|
| `script-src` | `'self'`, the page's nonce, `'wasm-unsafe-eval'` | loads scripts and module scripts from the origin and compiles WebAssembly; no inline script but the SDK, no `eval` |
| `worker-src` | `'self' blob:` | runs workers from `blob:` URLs its page makes from code the site served: a frame's origin is `null`, so it starts no worker from a URL of the site |
| `connect-src` | the endpoint's origin and `https://` each `tincture.connect` domain | fetches only its own files, the endpoint and the domains it declares; each declared domain is an exit, reached only by the source classes its `caps.flows` lets go there |
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

Declare `pointer_lock`, `fullscreen`, `gamepad` and `audio_autoplay` only as the game uses them; request fullscreen and pointer lock from a click or key press inside the frame. A frame that holds the pointer when a consent prompt opens may keep it: the prompt stays operable from the keyboard, Escape frees the pointer, and the frame cannot act on the prompt.

---

## Limits

| Limit | Setting | What happens |
|-------|---------|-------------|
| Requests per frame | `frame_invocation_max` per `frame_invocation_window_ms` (120 per minute by default), charged on every invoke, action and stream open; a public page is charged per address and tincture | refused `rate_limited` with its retry seconds |
| Open streams per frame | `frame_stream_max_concurrent` (8); a renewal keeps every open stream in its slot | refused `rate_limited` until one closes |
| Request body | a host call's body (1 MiB) per invoke, action or stream open | a declared length over it is refused 413 before any of the body is read; a body of undeclared length is read up to it, then refused 413; either way the call rejects |
| Frame credential lifetime | `frame_credential_deadline_s` (one hour), capped by the session's own | the shell renews it while the frame runs, a canvas's while it is shown; past the session's end, or a canvas hidden past it, refused: open the tincture again |
| Asset credential window | `asset_credential_window_s` (one hour) | the shell mints the next one |
| Version size | the registry's decompressed ceiling (256 MiB) | refused at publish |
| Handshake wait | 30 seconds | the SDK rejects with `no_frame` |

Each setting is a platform setting (see the [Configuration Guide](configuration-guide.md)). The consent profile the tincture runs under adds its own rate and budget.

---

## Security Model

- **The grant names the declaration.** A frame opens, and each of its requests is admitted, only under a grant whose shape names what its version declares. It reaches only the components in `dependencies.static`, the actions in `actions` and the streams in `streams`; everything else is refused before dispatch, and every request is recorded as the gate's decision.
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
| `no_frame` | the page is not a frame the shell opened, or the handshake never came | open the tincture from the shell, or publish it and use its public address |
| `forbidden` (`frame_suspended`) | the frame is hidden and does not declare `frame.background` | act when shown, or declare `background` |
| `forbidden` (`frame_moved`) | the version or its owner profile's grant changed since the frame opened | open the tincture again |
| `forbidden` (undeclared) | the component, action or stream is not in the declaration | declare it and publish a new version |
| `consent_required` | the tincture has no grant for the route that names what its version declares: none at all, one waiting for the person, or one made before the version declared more | grant it when the shell asks, or publish its public one |
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

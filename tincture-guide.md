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
| **Its files** | `/_s/<asset credential>/<publisher>/<name>/<version>/<file>`, only under a credential the shell minted for the person | `/t/@<namespace>/<publisher>/<name>` and the files under it, to anyone |
| **Opened by** | the shell, for the person whose athanor holds it | the shell, or anyone at its address |
| **Data requests** | the frame credential as a bearer | in the shell, the frame credential; at its address, the page names itself as `public` and sends no bearer |
| **Runs under** | the tincture's owner profile | the owner profile in the shell; its public profile at its address |

---

## App or Desktop

A tincture is an app or a desktop, and its manifest says which: the `tincture.desktop` block makes it a desktop, which the shell and the `canvas` tool call a canvas, and a tincture without the block is an app. An app opens over a desktop as a window, a tile or full, and reaches what its grant names: components, system actions, streams without a shape and origins of its own. A desktop is the person's own page beneath the apps: it fills the screen, reads the canvas-readable streams and feeds its block names, offers the controls its block declares, and reaches nothing of its own. Make an app for a tool that does something, and a desktop for a page that shows what is happening, with a few controls on it. `canvas.catalog` lists what a desktop may read; a desktop's block names only what its page opens.

| Field | App | Desktop | What it does | Bounds |
|---|---|---|---|---|
| `tincture.entry` | yes | yes | the page the frame opens | a safe relative path; a desktop's is `index.html`, or `dist/index.html` when it is built |
| `tincture.build` | yes | yes | `{"tool": "vite"}`: the version is built from its lockfile | a desktop's only with `dist/index.html` |
| `tincture.frame.capabilities` | yes | no | browser features delegated to the frame ([Frame capabilities](#frame-capabilities)) | at most 16, from that table |
| `tincture.frame.background` | yes | no | keeps the frame active while hidden | `true` or `false` |
| `tincture.frame.size` | yes | no | the size hint ([Sizes and placements](#sizes-and-placements)) | 100 to 4000 CSS pixels; `aspect` 1 to 100 |
| `tincture.streams` | yes | no | the streams the app may open | at most 32; never one that declares a shape |
| `tincture.actions` | yes | no | the system actions the app may run | at most 64 operation names; never the person's ([The declaration](#the-declaration)) |
| `tincture.connect` | yes | no | origins the page may connect to | bare domains |
| `caps.egress` | yes | no | where the app's runs may reach ([Integration Guide](integration-guide.md)) | its grammar |
| `dependencies` | yes | no | the components the app may invoke | its grammar |
| `tincture.subjects` | yes | no | the kinds of subject the app is opened with | each of `run`, `thread`, `schedule`, `component`, `file`, once |
| `tincture.desktop.data` | no | yes | the canvas-readable streams the page reads | at most 32 names `canvas.catalog` lists, each once |
| `tincture.desktop.feeds` | no | yes | the bound feeds the page reads, by name | at most 32 feed names, each once |
| `tincture.desktop.controls` | no | yes | controls the shell runs as the person on the person's tap | at most 32; `feed.press` or a direct write ([The canvas declaration](#the-canvas-declaration)) |
| `tincture.desktop.prefs` | no | yes | the schema of the desktop's preferences document | 32 widgets, 16 fields each |
| `tincture.desktop.chrome` | no | yes | the chrome declaration, read as tokens ([The chrome declaration](#the-chrome-declaration)) | a `.css` file in the version, at most 16,384 bytes |

Every key of the desktop block is optional. An app's grant covers its frame's capabilities and background, its streams and its actions; a desktop's covers its `data`, its `feeds` and its `controls`. A version that declares more asks again, and one that changes only a size hint, its subjects, its `prefs` or its `chrome` asks nothing again.

The smallest app and the smallest desktop that reads something:

```json
{"type": "tincture", "name": "viewer", "version": "0.1.0",
 "tincture": {"entry": "index.html", "frame": {"size": {"tile": "right"}}, "subjects": ["file"]}}
```

```json
{"type": "tincture", "name": "markets", "version": "0.1.0",
 "tincture": {"entry": "index.html", "desktop": {"data": ["runs.changes"], "feeds": ["btc"]}}}
```

---

## The Canvas

The shell — the **Canvas** mode on the top bar, at `/a/<athanor>/canvas` — shows the person's canvases and the tinctures opened over them. A **canvas** is a tincture whose manifest carries the `tincture.desktop` block, a desktop ([App or Desktop](#app-or-desktop)): the person's own page, written in HTML, CSS and JavaScript like any tincture, that shows what it reads.

The person's **layout** (`layout.get`, `layout.edit`) is a version-3 document: their canvases in order, at most eight, each with an `id`, the canvas tincture it runs (each canvas its own) and, per posture — `hand` under 768 CSS pixels wide, `desk` otherwise — the tinctures placed over it. A person has one layout in each athanor. A posture a canvas does not name places nothing. The layout names tinctures and where each stands and nothing else, so editing it can only arrange, and no canvas edits it. A person who never arranged one has the shipped layout: one canvas, `home`, running the shipped `tincture:local.canvas`, which shows their day in one sentence, what needs their attention grouped by cause (with a grant where one fixes it), their recent runs, their apps and their schedules with the week ahead. A layout is published only through the `layout` tool's `edit`. The CLI, the API and a device paired with the person call it for the person, and so does the assistant, whose shipped policy asks the person first. No tincture declares `layout.edit`, and no component but an agent that names it exactly is granted it. The shell calls it too, as the person, once their gestures on an app settle ([Sizes and placements](#sizes-and-placements)), writing the whole layout over the revision it last read; when a newer one was published meanwhile, it reads that one and makes on it each gesture that still applies. Every shell the person has open reads the layout again when an edit is announced, or on its next posture change or reconnect when the announcement does not go out.

The canvas the browser shows is the **visible canvas**, the layout's first when the shell opens. With more than one canvas, the person moves between them with the dots on the shelf the shell keeps along the bottom, with `Ctrl+Alt+1` to `Ctrl+Alt+8`, with `Ctrl+Alt+ArrowLeft` and `Ctrl+Alt+ArrowRight` while no app is active, or with a horizontal swipe on the shelf; nothing wraps at either end. Switching is the shell's alone: no canvas has a verb for it, so a broken canvas cannot hold the screen. Only the visible canvas reads and acts — a switch freezes the canvas it leaves, whatever it declares, with its apps unless they hold the background grant — and a tincture belongs to the canvas it was opened on. A layout with no canvas or a canvas whose tincture is not installed runs no canvas, and the shell draws its picker instead; launching a tincture from the picker opens it full. When the shell cannot read the layout, it says so on the screen: as it opens, it runs no canvas and draws its picker until a read succeeds, and later it keeps what it shows, the canvas, its refusal or the fallback, and applies a published change only once a read succeeds.

### Sizes and placements

A tincture's `tincture.desktop` block says what it is: without it the tincture opens as an app, and with it the tincture is a canvas. Over each canvas, per posture, the layout places apps, each in one of three placements:

| Placement | What is drawn |
|---|---|
| a `window` | the app's frame at its `geometry` (`x`, `y`, `w` and `h` in hundredths of a percent of the area between the top bar and the shelf), under a title bar the shell draws: dragged by its title, resized from any edge or corner |
| a `tile` | the app's frame at the left or right edge (`side`) with its `share` of that area's width, in hundredths of a percent, which narrows the canvas; resized from its divider |
| a `full` app | the app's frame over the whole area between the top bar and the shelf while it is shown, with its capsule |

Windows stand above tiles, and an app's `order` stacks windows and orders the tiles on each edge from left to right; a full app shown stands above both. A `minimised` app waits on the shelf with its placement kept. In the hand every app is full, whatever the layout stores. The person arranges apps with the chrome the shell draws outside every frame: dropping a window at the left or right edge of that area tiles it there and at the top makes it full, a double click on an app's title bar makes it full, and while the shell's page holds the focus `Ctrl+Alt` with the arrows tiles the active app left or right, makes it full or makes it a window again, `Ctrl+Alt+M` minimises it and `Ctrl+Alt+W` closes it. Every gesture but a minimise or a close raises the app, putting it last in that order: a window above every other window, a tile last among the tiles on its edge, and a window or tile raised over a full app hides that app, which keeps its placement until it is raised again. Each gesture is written to the layout once it settles; nothing is written while a drag or a resize runs.

An app may say how it would like to stand with a size hint, `frame.size`, which a canvas does not declare, since it fills the area: `min` and `preferred`, each a width `w` and a height `h` of 100 to 4000 CSS pixels, `preferred` at least `min` on each side; `aspect`, the width-to-height ratio as `w` and `h`, whole numbers from 1 to 100; and `tile`, `left` or `right`, for an app that would rather open tiled at that edge. Every part is optional and none is a requirement. A tincture the canvas opens that the layout does not place opens full in the hand; on the desk it opens as a tile at the edge its hint's `tile` names, or else as a window at the shell's default size, cascaded from the apps already there, and that placement is written to the layout. Of the hint, the shell reads `tile`; `min`, `preferred` and `aspect` are held to their bounds at publish and kept with the version. A hint is presentation, not reach: the grant does not cover it, so a version that only adds or changes a hint asks nothing again. A layout entry naming a tincture nobody installed opens nothing.

### The canvas declaration

A tincture is a canvas when its manifest carries the `tincture.desktop` block. Every key of the block is optional: `"desktop": {}` is a canvas that reads nothing, offers no control, keeps no preferences and wears Prism's default chrome, and a canvas adds only the keys it uses. It names its page as `tincture.entry`, on one of two templates: `vanilla`, `index.html` with no build, or `react`, `dist/index.html` built by `vite`, with `package-lock.json` beside `package.json`; its npm packages are bundled at build and never loaded from another origin. A canvas reaches nothing of its own, so it declares no `tincture.connect` origin, `caps.egress`, component dependency (static or dynamic), frame capability, `frame.background`, `frame.size`, action or `tincture.subjects`, and no `tincture.streams`: its block's `data` and `feeds` are its streams. Its entry is among the version's files, and of its `.html` files only the entry is ever a page. A manifest that names `frame.placement` is refused: the block is what makes a canvas.

- `data` names the streams the page reads, each one `canvas.catalog` lists (a stream that declares a shape) and that takes no subject; `feeds` names each bound feed it reads, whose results it reads from `feed.results` with the feed's name ([Streams and feeds](#streams-and-feeds)). At most 32 of each, each once.
- `controls` are what the shell runs as the person on the person's tap: each an `id` (lowercase letters, digits, `_` and `-`, unique in the block), a `label` of 1 to 32 code points, an `operation` (`tool.action`), its fixed `args` (an object), and at most one `pick`, the one argument the person chooses: from a stream the canvas reads (`stream`, a name in `data`, or `feed.results` with a `subject` in `feeds`), at an RFC 6901 pointer `field` into that stream's shape that is a string, a list of strings or an enum, filling the operation's argument `arg`: the choices are the strings the stream publishes there across its current state, so a control that pauses one of the person's schedules picks from `schedules.changes` at `/schedule_id`. A `feed.press` control fills its `pick` argument, which a feed's `run` action that names a `pick` passes to its operation as the argument it names ([Integration Guide](integration-guide.md)). A feed's `result` is the feed's own value, whose shape publish does not know, so a pick from `feed.results` takes a pointer beneath `/result/` (such as `/result/servers`), admitted by its form, and is refused at any other; each press checks the value against the feed's current result. On any other stream, a pointer that reaches a `json` value, or anything beneath one, is refused, since the stream's shape declares nothing there to choose from. Publish admits a control only when its operation is `feed.press` or a write the person makes directly. It refuses, naming which, an operation no provider declares; a person's own act (`schedule.create`, `schedule.update`, `feed.bind`, `feed.remove`, `layout.edit`, and every operation that asks for the person's confirmation, a grant among them); an administrator's; one that runs only inside a run; and every read, every other execute, and every destructive and external operation. The shell runs a control when the canvas presses it ([What a canvas may do](#what-a-canvas-may-do)), and holds it to these rules again then.
- `prefs` is the schema of the canvas's preferences document: `widgets`, at most 32 widget ids (lowercase letters, digits, `_` and `-`), each with up to 16 typed `fields`, and `desktop`, the canvas's own fields under the same grammar. A field's `type` is `boolean`, `integer`, `string` (with `max`, 1 to 256, default 256) or `enum` (with 1 to 64 distinct `values` of 1 to 256 code points). Every widget also carries the fields `on` (a boolean) and `rect` (`x`, `y`, `w` and `h` in hundredths of a percent, as the layout spells geometry: `x` and `y` from 0, `w` and `h` from 1, each to 10000), which its schema does not declare. Prism keeps one document per person and canvas, written only by the canvas's `cyfr.prefs` within the person's input and handed to the canvas when it opens ([The preferences document](#the-preferences-document)).
- `chrome` is the path of the canvas's chrome declaration among the version's files ([The chrome declaration](#the-chrome-declaration)).

What the canvas reads and runs, its `data`, `feeds` and `controls`, is in its grant: a version that changes them asks again. Its `prefs` and `chrome` carry no authority, so a version that changes only them asks nothing again.

```json
{
  "type": "tincture",
  "name": "markets",
  "version": "0.1.0",
  "tincture": {
    "entry": "index.html",
    "desktop": {
      "data": ["runs.changes", "schedules.changes"],
      "feeds": ["btc"],
      "controls": [
        {"id": "pause-digest", "label": "Pause", "operation": "schedule.pause", "args": {"schedule_id": "sch_1"}}
      ],
      "prefs": {"widgets": {"btc": {"fields": {"currency": {"type": "enum", "values": ["usd", "eur"]}}}}},
      "chrome": "chrome.css"
    }
  }
}
```

### The chrome declaration

A canvas's chrome declaration says how Prism's chrome looks while the canvas is shown. It is read at publish as a strict grammar into tokens and never as a stylesheet: the version's file routes never serve it, and the tokens are kept with the version (`Prism.TinctureRegistry`). While the canvas is the one shown, Prism applies its tokens as its own variables to the shelf, the dots, the top bar and the window chrome (`assets/css/canvas_chrome.css` is written against them), and its own look stands again when another canvas is shown, the canvas falls back, or the person leaves the canvas. Prism wears its dark theme, so a canvas's `-dark` colours apply, and its light ones where it declares only those. A texture or a font is loaded from the version's own files; nothing the file says beyond the tokens reaches Prism's page. The system layer's prompts take none of it and keep Prism's own theme. The file is at most 16,384 bytes of ASCII text, with at most one `:root` rule and any number of `@font-face` rules:

| Declared | Value |
|---|---|
| `--chrome-ground`, `--chrome-surface`, `--chrome-ink`, `--chrome-accent`, and each with `-dark` | a colour, `#rgb` or `#rrggbb`; a mode's four together, its ink at least 4.5 to 1 and its accent at least 3 to 1 against its ground |
| `--chrome-radius` | 0 to 24px |
| `--chrome-border` | 0 to 4px |
| `--chrome-edge` | 4 to 16px |
| `--chrome-title-height` | 28 to 56px |
| `--chrome-controls` | `left` or `right` |
| `--chrome-title-align` | `left` or `center` |
| `--chrome-glyphs` | `plain`, `round`, `square` or `pixel` |
| `--chrome-font` | `system`, or the quoted family a `@font-face` of the file declares |
| `--chrome-texture-title`, `--chrome-texture-shelf` | `url()` of a PNG or an SVG in the version, at most 524,288 bytes and 2048 pixels a side; an SVG's root element says its `width` and `height` |
| `@font-face` | exactly `font-family`, a quoted family of letters, digits, spaces, `_` and `-`, and `src`, `url()` of a WOFF2 in the version, at most 524,288 bytes, optionally with `format("woff2")` |

A length is a whole number of `px`. A `url()`, quoted with `"` or not, names a path relative to the chrome file's directory, of plain segments: never `..`, an absolute path or another origin. Each declaration ends with `;` and is declared once. A font is shipped under its author's licence, and keeping to it is the author's: CYFR asks for no licence file, and a version that ships a font its licence does not let it carry is its author's to withdraw. Anything else, another selector, property or at-rule, a comment, an escape, `!important`, an uppercase name or a value outside its bound, refuses the publish, naming the file and the line, and nothing of the version is installed.

```css
:root {
  --chrome-radius: 12px;
  --chrome-title-height: 34px;
  --chrome-controls: right;
  --chrome-font: system;
}
```

### The preferences document

A canvas keeps what the person sets on it, which widgets are on, where each stands and its own fields, in a preferences document: one per person and canvas (the layout's canvas id), in the athanor, never another person's and never another athanor's. It is at most 16,384 bytes as canonical JSON:

```json
{"widgets": {"runs": {"on": false, "rect": {"x": 0, "y": 0, "w": 5000, "h": 4000}}}, "desktop": {"compact": true}}
```

The canvas reads it at its open, with its `revision`, as `cyfr.desktop.prefs`, reduced to what its version's `prefs` declares (a widget or a field it no longer declares, or a value its schema no longer admits, is left out). `cyfr.prefs(document)` writes it, only within the person's input: `document` names `widgets`, `desktop` or both, each widget it names replacing that widget's whole entry and `desktop` the whole section, everything else kept. The write goes over the revision the canvas holds. Each write is answered on its own, whatever order the shell answers writes in: `saved` with the document now stored; `stale` with the current document when another of the person's screens wrote first, nothing merged, so the canvas writes again over it; `refused` with its reason for a document the schema refuses or one past the bound, the stored one left as it was; or `cancelled` when no input of the person's carried it, with `reason` `too_soon` when it came within a few seconds of the last spend of the activation.

### The canvas page

The shell frames a canvas at `GET /_c/v1/<asset credential>/<frame id>`, one page for one open, never cached. It is the version's entry document with two things first in its `<head>`: a `<base>` naming the version's served files, so the page's relative URLs (`app.js` beside a vanilla `index.html`, `./assets/…` from Vite's `base: "./"`) load its own files, and then the SDK, loaded by `<script src>` from CYFR's one fixed path. CYFR's `<base>` comes first, so one the page writes is ignored. Every refusal is a 404 with an empty body — an asset credential that does not stand, a frame id naming no standing frame of the credential's person, athanor and version, a release digest that moved, or a version that declares no desktop block — and a store that cannot say answers 503. The path carries the asset credential, so no proxy may log `/_c/v1/` paths either.

The page's policy (`Compendium.Tincture.Rules.canvas_page_csp/1` holds its directives) admits:

- scripts from the version's files and the SDK's path, and no inline script at all, so keep every script in a file;
- styles from the version's files and inline styles, so an `@import` too reaches only the version's files;
- images, fonts and media from the version's files alone, and an image also from a `data:` or `blob:` URL;
- workers from the version's files or `blob:` URLs, under this same policy;
- requests to the version's files and the open's own stream connection, under its data path over the endpoint's WebSocket origin (`ws://` or `wss://…/_f/v1/o/<frame id>/`), and nowhere else;
- no frame, plugin or form of its own, and a sandbox of `allow-scripts` alone: no popup and no top-level navigation.

Nothing on those paths redirects.

### What a canvas may do

On a canvas's page the SDK carries these calls:

- **`cyfr.stream(name, subject, onEvent)`** opens a stream the version declares, as on any tincture, over the canvas's own stream connection, `GET /_f/v1/o/<frame id>/socket`; a name and subject the version does not declare is refused before anything is sent.
- **`cyfr.on(event, handler)`** calls `handler` with each value the shell sends of `installed` (the installed tinctures that are not canvases, as `[{ref, name, icon, open}]`), `posture` (`hand` or `desk`), `covered` (the rectangles of the canvas, in its own pixels, that the windows over it cover; a tile narrows the canvas's frame instead, and a full app hides it), `state` (`live` or `frozen`) or `desktop` (as `cyfr.desktop` reads it).
- **`cyfr.open(ref)`** opens an installed tincture where the layout places it, or where [Sizes and placements](#sizes-and-placements) says, raised among the apps of its kind; one already open is raised and one minimised comes back, and one `installed` does not list is dropped.
- **`cyfr.open(ref, subject)`** with a subject, `{kind, id}`, opens an app on it: the kind must be one the app's `tincture.subjects` declares, the id a well-formed one (1 to 256 letters, digits and `_ . : @ / -`), and the app reads it as `cyfr.subject` once it opens. Opening it does nothing more: what the subject names is the app's to read under its own grant. An app already open is raised and told the new subject.
- **`cyfr.press(control, value)`** presses a control the canvas declares, by its `id`, with the `value` it picked when it has a `pick`. The shell reads the press against the served version's declaration and the rules publish holds controls to, reads the picked stream's current state at that moment and refuses a value it does not publish there, and runs the operation through the gate as the person, which decides whether the person may reach what it names. It resolves with its own press's outcome, whatever order the shell answers presses in: `{outcome: "accepted"}`, `{outcome: "refused", reason}` with the refusal's class, or `{outcome: "cancelled"}` when no input of the person's carried it or the canvas was not shown, and `{outcome: "cancelled", reason: "too_soon"}` when it came within a few seconds of the last spend of the activation ([What a canvas may do](#what-a-canvas-may-do)). Nothing is tried again, and one the shell never answers resolves as refused `uncertain` after 30 seconds.
- **`cyfr.press(binding, action)`**, its first argument a binding id, presses an action of a feed the canvas declares, `binding` the binding id of that feed's latest result; it answers nothing.
- **`cyfr.prefs(document)`** writes the person's preferences for the canvas ([The preferences document](#the-preferences-document)).
- **`cyfr.ask(widget)`** opens AQUA's panel with a sentence CYFR writes naming the widget (one the canvas's `prefs` declares) and the canvas, after any draft the person has; it attaches nothing and sends nothing.
- **`cyfr.settings(page)`** opens one of CYFR's own pages by its key, such as `schedules`, `vault` or `settings`, from the list the Dashboard's menu holds; today that leaves the canvas for the page.
- **`cyfr.grant(ref)`** asks the person to grant an installed component, named by its reference: CYFR's own grant prompt opens, and the person confirms it there or not.
- **`cyfr.desktop`** is what the canvas's open told it: `prefs` (its preferences and their `revision`), `appearance` (`mode`, `light` or `dark`; `accent`, Prism's accent colour; the person's `locale`, `time_zone` and `safe_areas`, the screen's insets in CSS pixels) and `person` (`name`, the person's display name, or null; never an email, a handle or an id). `cyfr.on("desktop", handler)` hears it at the open and after each answered write.
- **`cyfr.ready()`** tells the shell the canvas has drawn.

<!-- tincture:canvas -->
| Call | Carried by |
|---|---|
| `cyfr.press(control, value)` | the shell's port, `press` |
| `cyfr.grant(ref)` | the shell's port, `grant` |
| `cyfr.prefs(document)` | the shell's port, `prefs` |
| `cyfr.ask(widget)` | the shell's port, `ask` |
| `cyfr.settings(page)` | the shell's port, `settings` |
| `cyfr.on("installed", handler)` | the shell's port, `installed`: each tincture's `icon`, `name`, `open`, `ref` |
<!-- /tincture:canvas -->

The shell drops a canvas's `close`, `title` and `credential`, and the shared routes refuse its credential, so `cyfr.invoke` and `cyfr.action` reject: a canvas writes nothing and invokes no component.

The shell honours a canvas's `open`, `press`, `grant`, `prefs`, `ask` and `settings` only for an input of the person's, never from a script on its own, and one input carries one of them. The shell's page sees no input made inside a frame; it sees the activation an input gives the page for a few seconds, and every input in CYFR's own chrome. So a call goes only when the page holds activation that neither an input in the chrome, the canvas's own opening nor the canvas's last call has spent, with the canvas focused, shown and live; a call sent within a few seconds of such a spend is dropped at once, never held. A press in the chrome followed by the canvas focusing itself therefore passes nothing, nor does a canvas that opens on a tap and focuses itself, two calls from one tap pass one, and a tap within a few seconds of a press in the chrome or of the canvas's last call passes nothing, for the person to tap again. A dropped press of a control or write is answered `cancelled`, naming `too_soon` when it came within those seconds of a spend.

Every label a canvas shows, on a control or anywhere else, is the canvas's own text: CYFR does not check that a control says what it does.

An error the page does not catch before `cyfr.ready()` — a throw, or a rejection nothing handles, such as a refused `cyfr.stream` without a `catch` — fails the canvas. The canvas shown falls back ([The fallback](#the-fallback)); a version on trial fails its validation, and the working version opens, or the canvas falls back when it has none ([Validation and the kept version](#validation-and-the-kept-version)). One after `cyfr.ready()` is not a failure: the SDK reports nothing, and the canvas stays. The browser's benign ResizeObserver loop messages are ignored.

A canvas holds a window, so what it reads can leave the browser like any app's: through a message to another frame, which no page policy closes, or a peer connection, which its policy closes only in Chromium. It changes nothing in CYFR by itself: its credential reaches only its own streams, and the shell acts on its opens, presses and writes only for an input of the person's, a control only as the person may run it. Only the person's own canvases open: a canvas from a publisher other than `local` falls back instead.

### Streams and feeds

A canvas reads only the streams its block declares, its `data` and its `feeds`, and only a stream whose provider declares a shape for it; `canvas.catalog` lists them with their shapes. A field with finitely many values, such as a run's `error.cause`, is an `enum` whose `labels` give each value its readable sentence, so a canvas shows the sentence for the value it reads. Such a stream is a canvas's alone: publish refuses one in any other declaration, and an open from any other tincture's frame is refused `forbidden` (`canvas_stream`). Each is handed its current state first, each item marked `refresh: true`, and then its live events; an event that races the current state may arrive twice, so a canvas takes a feed's result once per `revision`, a run's change once per `execution_id` and `kind`, a schedule run once per `occurrence_id` and `kind`, and a schedule's change as that schedule's latest state; every other stream's item is that item's latest state, keyed as the [Integration Guide](integration-guide.md) says.

| Stream | Subject | What a canvas reads |
|---|---|---|
| `runs.changes` | — | each run's `kind`, `execution_id`, `parent_execution_id`, `reference`, `component_type`, `duration_ms` and `error` (its `class` and `cause`, never a sentence), after the athanor's 20 newest runs |
| `schedules.changes` | — | each schedule's `kind` (`changed` or `removed`), `schedule_id`, `name`, `reference`, `cron_expression`, `status`, `next_run_at`, `last_run_at`, `run_count` and `error_count`, after every live schedule of the athanor as `changed` |
| `schedule_runs.changes` | — | each run of a schedule as its `kind` (`fired` or `failed`), `schedule_id`, `occurrence_id`, `execution_id`, `scheduled_for` and `reason` (its `class` and `cause`), after the athanor's 20 newest occurrences of schedules; a feed's fire is not a schedule run |
| `feed.results` | a feed's name | each accepted result of that feed as its `binding` id, `feed`, `revision`, `at`, `result`, `label` and `actions`, after its last accepted result |
| `activity.changes` | — | each crew job as its `kind` (`started` or `ended`), `id` (its key: one member may hold several jobs), `member`, `asked_by`, `since` and `status`, after every open job of the athanor's crew |
| `attention.changes` | the holder's own user id | what waits for the person, each as its `kind` (`approval`, `confirmation`, `failed_run`, `failed_schedule`, `file_offer`, or `removed`), `id`, `label`, `since` and `destination`, after everything waiting now |
| `components.changes` | — | each installed component as its `kind` (`installed`, `removed`, `pushed`, `changed`), versionless `ref`, `type`, `name`, `icon`, `version`, `update_available` and `grant_current`, after every installed version; a `changed` asks the canvas to open the stream again |
| `vault.changes` | — | each standing vault entry as its `kind` (`changed` or `removed`), `name`, `type` and `status` (`fine` or `needs_reauthorisation`), after every standing entry; never a value |
| `threads.changes` | the holder's own user id | each thread of the person's list as its `kind` (`own`, `shared`, or `removed`), `id`, `title`, `people`, `last_activity` and `waits_on_you`, after the whole list |

A canvas names every feed it reads in `feeds`, each name once, and reads its results from `feed.results` with the feed's name as the subject. A feed is bound with the `feed` tool, by the person or by the assistant with the person's approval (the [Integration Guide](integration-guide.md) lists it); a canvas's code has no verb that binds, changes or refreshes one. From a canvas, a feed's action runs only on a press the shell forwards within moments of the person's own input, never from a script on its own, and sends to `feed.press`; the CLI and the API reach `feed.press` as they reach any external operation, and no chain does. The canvas's data path admits only that open's credential and has no invoke and no action route. Every stream a canvas reads rides its one stream connection, so a canvas reads every stream it declares at once, up to 32, over plain HTTP as over HTTPS: there is no budget of connections to keep under, and no need to open a part's streams only while that part is on.

### Validation and the kept version

A canvas changes only as a new version: `canvas.write` creates the next version whole, a version's files are never replaced, and the publish check holds each version as it does any tincture's. When a browser is to show a canvas whose newest installed version is neither its working version, its kept version nor its last failed one, the shell first validates that version in a bounded mode. It opens the version once in a hidden, inert frame under a **validation credential**, which carries no live authority: each declared stream the candidate opens is answered once from a fixture of its shape — for a feed, of the result shape of the feed the athanor binds under that name, and nothing for a name it does not bind — and then ends, admitting nothing. From that frame the shell acts only on `ready` and `failed`. The candidate must call `cyfr.ready()` within ten seconds of its frame's open. The shell tears the frame down on `ready`, the deadline, a failure or the frame's death, and reports the outcome — `ready`, `not_ready` or `died` — to `canvas.activate`, which spends the credential; a deadline that comes before the page loaded, as when the browser abandons the trial's load because the person reloaded, reports nothing, and the version is validated again at the next show. Only `ready` activates: the version becomes the working one once its grant is current (the grant prompt asks otherwise, and the version is validated again after it), and the version it replaces is kept. Any other outcome records the failure. Once a validation ends the browser compares again: a newer version written meanwhile that needs validating is validated in its turn, each such version once, and otherwise the browser opens the working version, or, when there is none, falls back ([The fallback](#the-fallback)). A version written while no browser shows its canvas waits for one. The kept version is the way back, restored by `canvas.restore` under today's grant, so a kept version is never kept permission.

### Hidden, frozen and background frames

The frame the person looks at is live. With a full frame shown, every other frame — the canvas among them — is hidden, as is every canvas the browser does not show, with its apps, and a hidden frame without `frame.background: true` is frozen: its credential is suspended before its bridge is told, its element is inert, and its requests are refused as `frame_suspended` until it is shown again; a validation's frame is hidden but never frozen, since its credential is never suspended. A frame that declares the background grant keeps running hidden. A hidden canvas is frozen whatever it declares, so it reads nothing and acts on nothing: it hears `state` `frozen`, its streams close with its suspended credential, a stream it asks for sends nothing until it is shown and opens then, and its opens and presses are dropped. Its JavaScript may keep running until the browser discards the frame, and what it reports of itself still counts: a hidden canvas that calls `cyfr.ready()` is ready, and one that fails before it falls back once it is shown. Shown again, it hears `state` `live` and reads again, and a stream it opens again refreshes first. A frame never raises itself: no verb places, sizes or raises a frame.

### The fallback

The way back from a broken canvas is outside every canvas. The canvas the browser shows falls back when it has not sent `ready` within ten seconds of being shown, fails before `ready`, cannot be opened, or its frame goes away while it is shown (its page loaded a second time); so does a canvas that failed before `ready` while hidden, once it is shown, and a canvas whose new version failed its validation and that has no working version. A canvas refused for want of the person's grant does not fall back: it shows its refusal and offers the grant prompt. A hidden canvas owes no `ready`: the ten seconds run from its frame's open for a canvas that opens shown, and otherwise from the moment it is shown, and a canvas ready before it was hidden stays ready.

Falling back shows the shipped canvas in its place, in this browser, with no validation and no write, and keeps every app over it, every other canvas and the assistant's panel as they are, so the person goes on working. One line on the shelf says "Your canvas stopped. Showing the standard one." and offers Try again, which opens the canvas again as it now stands, and, while the canvas keeps one, Restore the last working one, which `canvas.restore` makes its working version again under today's grant. The fallback stands until the person chooses one of those, or until a published layout names another tincture for that canvas or drops it; a layout that only arranges keeps it. While it stands, the failed canvas's late `ready` changes nothing, and if the shipped canvas's own frame goes away, nothing opens in its place until the person tries again.

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

A public tincture is served at its address, `/t/@<namespace>/<publisher>/<name>`, `@<namespace>` being the personal namespace of the person whose athanor publishes it, with its files under it. The address follows the tincture's latest version. A canvas is never public: it is the person's own data page, so no public profile is staged for one and the public route serves none.

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
| `frame` | object | — | The frame's capabilities, background flag and size hint (below) |
| `streams` | object[] | `[]` | The streams an app may open (below) |
| `actions` | string[] | `[]` | The system actions an app may run, as `tool.action` |
| `subjects` | string[] | `[]` | The kinds of subject an app is opened with: `run`, `thread`, `schedule`, `component`, `file` |
| `desktop` | object | — | Makes the tincture a desktop, a canvas, every key optional ([The canvas declaration](#the-canvas-declaration)) |

### The declaration

`frame`, `streams`, `actions` and `desktop` are the tincture's declaration. It is held to the rules at publish and read again at every open and every request, and it is never the grant: a version opens only under its owner profile's grant whose shape names what the version declares, so a tincture with no grant, or a version that declares more than its grant names, opens nothing and the shell asks the person for the grant instead. Anything a frame asks for outside its declaration is refused before it is dispatched.

<!-- tincture:declaration -->
| Block | Keys |
|---|---|
| `frame` | `background`, `capabilities`, `size` |
| `frame.size` | `aspect`, `min`, `preferred`, `tile`: `min` and `preferred` each `w` and `h`, 100 to 4000 CSS pixels; `aspect` `w` and `h`, whole numbers 1 to 100; `tile` one of `left`, `right` |
| `streams[]` | `name`, `subject` |
| `actions[]` | an operation name, `tool.action` |
| `subjects[]` | one of `run`, `thread`, `schedule`, `component`, `file` |
| `desktop` | `chrome`, `controls`, `data`, `feeds`, `prefs`, each optional |
| `desktop.data[]`, `desktop.feeds[]` | at most 32 each: a stream's name, a feed's name |
| `desktop.controls[]` | `args`, `id`, `label`, `operation`, `pick`: at most 32; `label` 1 to 32 code points |
| `desktop.controls[].pick` | `arg`, `field`, `stream`, `subject` |
| `desktop.prefs` | `desktop`, `widgets`: at most 32 widgets, each section at most 16 `fields` of `boolean`, `integer`, `string`, `enum`; `string` `max` 1 to 256; `enum` 1 to 64 `values`; never a widget field `on`, `rect` |
| `desktop.chrome` | a relative path to a `.css` file in the version |
<!-- /tincture:declaration -->

- `frame.capabilities` names capabilities from the table below; `frame.background: true` keeps the frame active while hidden; `frame.size` is the size hint, which declares nothing ([Sizes and placements](#sizes-and-placements)).
- A stream's `name` is a stream a provider declares (two or more dotted names, such as `mcp_servers.changes`); its `subject` is a literal, `"*"` for any subject that stream's grammar admits, or absent for a stream that takes none.
- A stream that declares a shape (each one `canvas.catalog` lists, such as `runs.changes` or `feed.results`) is a canvas's alone, named in its desktop block: publish refuses it in an app's `streams`, whatever its subject, and an open from any other tincture's frame is refused `forbidden` (`canvas_stream`) ([Streams and feeds](#streams-and-feeds)).
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
| `cyfr.stream(name, subject, onEvent)` | the stream connection, `GET /_f/v1/socket` |
| `cyfr.open(ref, subject)` | the shell's port, `open` |
| `cyfr.close()` | the shell's port, `close` |
| `cyfr.title(title)` | the shell's port, `title` |
| `cyfr.ready()` | the shell's port, `ready` |
| `cyfr.credential(name)` | the shell's port, `credential` |
<!-- /tincture:sdk -->

- **`cyfr.invoke(ref, operation, args)`** runs a component the tincture declares in `dependencies.static`. The component runs with the input `{"operation": …, "params": …}` — `operation` the name given, `params` the `args` object — and the promise resolves with `{status, output, execution_id, duration_ms}`.
- **`cyfr.action(name, args)`** runs a system action the declaration's `actions` lists (`"tool.action"`), with `args`, and resolves with its result.
- **`cyfr.stream(name, subject, onEvent)`** opens a stream the declaration's `streams` lists, with a literal subject or `null` for one that takes none. Every stream a frame opens rides one stream connection, a WebSocket the SDK opens with the first and opens again after it closes, so a frame reads as many streams at once as it declares, up to 32, whatever the browser's limit on connections to one host. It returns a promise that resolves, once the stream is open, with a handle: `handle.close()` ends it, freeing its place at once, and `handle.closed` settles when it ends, whether the grant's deadline passed, the endpoint closed it or `close()` was called, and rejects when the connection broke. The promise carries the same `close()`, so a stream still waiting for its answer is cancelled through it, and rejects `cancelled`. `onEvent` is called with `{id, event, data}` per event: `id` the sequence number where the topic carries one, `event` the stream's name, `data` the payload projected to the grant's fields. A stream the endpoint closes for a reason the frame should know ends with an event named `refusal`. A reconnect is a new `cyfr.stream` call, admitted again.
- **`cyfr.open(ref, subject)`** asks the shell to open another tincture it lists, optionally on a subject of a kind that app declares; an app opened on one reads it as **`cyfr.subject`** (`{kind, id}`, or null), and an app opened again on another is told it: `cyfr.subject` changes and **`cyfr.on("subject", handler)`** hears it. **`cyfr.close()`** closes this frame; **`cyfr.title(title)`** sets its title (at most 120 characters); **`cyfr.ready()`** tells the shell the tincture has loaded. No verb places, sizes or raises a frame: which frame is shown is the shell's and the person's. Shell verbs made before the handshake wait for it; outside a frame they do nothing.
- **`cyfr.credential(name)`** asks the person for a secret through the shell's own prompt, to be stored in the vault as the entry `name`; see [Secrets](#secrets). It resolves with `{saved}` once the prompt closes.
- On a canvas's page, **`cyfr.on(event, handler)`**, **`cyfr.desktop`**, **`cyfr.press(control, value)`**, **`cyfr.prefs(document)`**, **`cyfr.ask(widget)`** and **`cyfr.settings(page)`** carry what the shell sends the canvas and what the canvas asks of it for the person ([What a canvas may do](#what-a-canvas-may-do)).
- `cyfr.frame` is the frame id the shell handed this frame (`null` before the handshake), and `cyfr.public` the public tincture a top-level page names itself as (`null` in a frame).

A refusal rejects with a `CyfrError`: `message` is the sentence, `code` the refusal's class (`unauthenticated`, `forbidden`, `not_found`, `rate_limited`, `consent_required`, `invalid_argument`, `unavailable`, …) and `stage` whether it was refused at `admission` or during `execution`. A `cyfr.stream` open that got no answer — the endpoint could not be reached, the connection broke or closed first, or it was refused for a fault of the server's (`unavailable`, `timeout`, `internal` and the like) — rejects as `unavailable` with no `stage`, whatever the error said, and may open if tried again later; opened again after any other refusal, it meets that refusal until something changes. A frame that has no credential yet waits up to 30 seconds for the shell's handshake and then rejects with `no_frame`.

**Public mode.** A public tincture's page opened at its address, outside any frame, has no shell and no credential: the SDK names the tincture from the page's path as `public: {athanor, publisher, name}` in each request and sends no bearer. The endpoint admits such a request only for a tincture that is public, under its public profile; it opens no stream, and `cyfr.stream` rejects `no_frame`. Any other top-level page — a private `/_s/` page among them — answers `no_frame`.

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

The SDK is the only client of two routes, each a `POST` of a JSON body carrying `v` (the wire version) with the frame credential as `Authorization: Bearer <credential>` — never in a URL or a body — and of the frame's stream connection:

<!-- tincture:wire-routes -->
| Request | Route |
|---|---|
| `action` | `POST /_f/v1/action` |
| `invoke` | `POST /_f/v1/invoke` |
| the stream connection | `GET /_f/v1/socket`, a WebSocket |
<!-- /tincture:wire-routes -->

An `invoke` or `action` answers `{"v", "ok": true, "result"}`, a refusal `{"v", "ok": false, "error": {"class", "message", "stage"}}`. The stream connection carries one JSON message per text frame, each with `v`: the frame sends `subscribe` (its own number for the stream, the newest frame credential, the stream's name and subject) and `unsubscribe` (the number), and the endpoint answers each number `subscribed`, then its `event`s, each tagged with the stream and the subject, and `ended`, with the refusal as `error` when it was refused or closed for a reason the frame should know. The credential travels in each `subscribe`, never in the connection's URL. One connection carries at most 32 streams, takes no message over 4 KiB, and closes when it has held no stream for a minute; a frame holds one connection, and a newer one replaces the older. These routes carry no session cookie and no CSRF token: the bearer is the only credential, and the `null` origin of a sandboxed frame is answered on these routes alone. `Prima.TinctureWire` defines the shapes and `tests/fixtures/tincture_wire.json` holds one of each. A canvas's SDK opens its stream connection on the canvas's own data path, `GET /_f/v1/o/<frame id>/socket`, instead, and makes no other request ([What a canvas may do](#what-a-canvas-may-do)).

---

## What the Frame May Do

The frame's document is sandboxed without `allow-same-origin`, so its origin is `null` to every browser, and its policy is derived from its declaration as this table gives for every tincture but a canvas, whose page's policy [The canvas page](#the-canvas-page) gives:

| Directive | Value | So the tincture |
|---|---|---|
| `script-src` | `'self'`, the page's nonce, `'wasm-unsafe-eval'` | loads scripts and module scripts from the origin and compiles WebAssembly; no inline script but the SDK, no `eval` |
| `worker-src` | `'self' blob:` | runs workers from `blob:` URLs its page makes from code the site served: a frame's origin is `null`, so it starts no worker from a URL of the site |
| `connect-src` | the endpoint's origin, its WebSocket origin (`ws://` or `wss://`, for the stream connection) and `https://` each `tincture.connect` domain | fetches only its own files, the endpoint and the domains it declares; each declared domain is an exit, reached only by the source classes its `caps.flows` lets go there |
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
| Requests per frame | `frame_invocation_max` per `frame_invocation_window_ms` (120 per minute by default), charged on every invoke and action and once per stream connection; a public page is charged per address and tincture | refused `rate_limited` with its retry seconds |
| Open streams per frame | 32 on its one stream connection; a closed stream frees its place at once, and a renewal keeps every open stream | refused `rate_limited` until one closes |
| Stream connection message | 4 KiB per message the frame sends | the connection closes |
| Request body | a host call's body (1 MiB) per invoke or action | a declared length over it is refused 413 before any of the body is read; a body of undeclared length is read up to it, then refused 413; either way the call rejects |
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

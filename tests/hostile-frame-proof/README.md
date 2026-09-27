# The frame sandbox containment proof

`run.sh` proves, on the browser harness (`tests/browser/`), what a tincture
that declares nothing can do from inside the frame the Prism shell creates
for it. The probe (`tinctures/containment-probe/`) is published twice into a
signed-in person's athanor, private and public, and opened from the shell in
Chromium, Firefox and WebKit. `proof.mjs` drives one attempt at a time and
reads each where it can be seen: in the frame, at the harness's proxy, at a
recording endpoint on a foreign origin, in a sibling frame, in the shell.

Every attempt has one column, and the proof fails when an attempt leaves it:

- **allowed** — the bundle's own function, which the sandbox must not break;
- **refused** — nothing of the attempt takes effect, and nothing of it
  reaches the recording endpoint;
- **disclosure** — a route that stays open, asserted to carry nothing the
  tincture was not given.

## Expected outcomes

| Attempt | Column | What holds |
|---|---|---|
| `module_script` | allowed | a module script of the bundle runs |
| `blob_worker` | allowed | a worker from a blob of the bundle runs |
| `wasm_instantiate` | allowed | a WebAssembly module instantiates |
| `public_neighbour_script` | allowed | a public tincture's script loads and runs under the loader's grant |
| `private_neighbour_script` | refused | another private version's script does not load |
| `form_post` | refused | a form POST leaves nothing at the recording endpoint |
| `top_read` | refused | the shell's location and document cannot be read |
| `top_navigate` | refused | the shell's page cannot be navigated |
| `opener` | refused | the frame has no opener |
| `popup` | refused | the frame opens no window |
| `fetch_undeclared` | refused | a fetch to an undeclared origin is refused before it is sent |
| `image_beacon` | refused | an image from an undeclared origin is refused before it is sent |
| `send_beacon` | refused | a beacon to an undeclared origin is refused before it is sent |
| `redirect_fetch` | refused | an asset fetch redirected to an undeclared origin is not followed there |
| `asset_credential_on_data_route` | refused | the asset credential opens no data route (private only) |
| `undeclared_invoke` | refused | a component the declaration does not name is refused at admission |
| `undeclared_action` | refused | a system action the declaration does not name is refused at admission |
| `undeclared_stream` | refused | a stream the declaration does not name is refused at admission |
| `fullscreen_undeclared` | refused | fullscreen without the declared capability is refused |
| `cookie_and_storage` | refused | the frame reads no cookie and holds no storage |
| `suspended_invoke` | refused | a call made after the shell suspended the frame is refused |
| `self_navigation_foreign` | refused | the frame's navigation of itself to a foreign origin reaches nothing: the shell's `frame-src 'self'` governs where its frames navigate |
| `self_navigation_session_page` | refused | the frame's navigation of itself to a page that reads the session draws none of it: a Prism page is framed by nothing |
| `frame_request_refused` | refused | a page that reads the session answers 403 to a request whose destination is a frame, before the session is read, and sets no cookie |
| `sibling_message` | disclosure | a post to a sibling's window arrives as a message from an opaque origin, and changes neither the sibling's frame identity nor the shell |
| `shared_credential_url` | disclosure | a credential address serves that version's bytes to whoever holds it, for the credential's window (private only) |
| `self_navigation_site` | disclosure | the frame may navigate itself within the site; the navigation carries the frame's own address and no referrer |
| `session_blind_page` | disclosure | a tincture's page answers the same with the session cookie and without, and sets none |

## The session cookie on a navigation within the site

Whether the person's session cookie goes with `self_navigation_site` is the
browser's decision. Chromium and Firefox treat a navigation a sandboxed frame
starts as cross-site and send none; WebKit sends it. `proof.mjs` holds each
browser to its recorded answer (`COOKIE_ON_SITE_NAVIGATION`), so a browser
that changes fails the proof.

Where the cookie is sent, the tincture does not receive it. The cookie is
`HttpOnly`; the document that lands replaces the tincture's and stays in the
frame's sandbox under an opaque origin; and the only pages of the site that
run a tincture's code are served by routes that read no session
(`session_blind_page`). A route that does read the session refuses a request
whose destination is a frame (`CyfrWeb.Plugs.FrameRequest`), and its pages are
framed by nothing, so a browser that does not name the destination still draws
none of them (`self_navigation_session_page`). Browsers name a request's
destination only to a secure origin, which the harness's is not, so
`frame_request_refused` asks the server directly.

## Not driven

| Attempt | Why |
|---|---|
| `grant_prompt_fullscreen` | fullscreen reacquired while a grant prompt is up: nothing in this proof opens a grant prompt, since its probe declares nothing and the shell offers a grant only to a tincture whose owner profile needs consent again |
| `suspended_on_another_member` | an action after the frame was suspended on another member: the proof runs at one member, and makes the suspension through the shell (`suspended_invoke`) |

## Record

Recorded on 2026-09-26 on `p1` (`tests/browser/README.md`) by `run.sh`, each
cell private / public.

| Attempt | Chromium 153 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| every allowed attempt | held / held | held / held | held / held |
| every refused attempt | held / held | held / held | held / held |
| `sibling_message` | held / held | held / held | held / held |
| `shared_credential_url` | held / not applicable | held / not applicable | held / not applicable |
| `self_navigation_site` | held / held | held / held | held / held |
| `self_navigation_session_page` | held / held | held / held | held / held |
| session cookie sent on `self_navigation_site` | no | no | yes |
| `session_blind_page` | held (asked of the server) | | |
| `frame_request_refused` | held (asked of the server) | | |

# The frame sandbox containment proof

`run.sh` proves, on the browser harness (`tests/browser/`), what a tincture
that declares nothing can do from inside the frame the Prism shell creates
for it. The probe (`tinctures/containment-probe/`) is published twice into a
signed-in person's athanor, private and public, and opened from the shell in
Chromium, Firefox and WebKit. `proof.mjs` drives one attempt at a time and
reads each where it can be seen: in the frame, at the harness's proxy, at a
recording endpoint on a foreign origin, in a sibling frame, in the shell.

A second probe (`tinctures/fullscreen-probe/`) is the malicious fullscreen
frame: it declares fullscreen and pointer lock, and the `vault.create`
action a credential prompt needs. One click takes fullscreen and locks the
pointer once it is fullscreen; another locks the pointer and, inside the
same gesture, asks the shell for a credential prompt through the frame's
own `credential` verb. It asks again for fullscreen and for the pointer
whenever it loses either. While it holds both, the server opens a system
layer prompt over it: a grant prompt, by publishing a layout that floats a
tincture whose consent waits to be given again
(`tinctures/ungranted-probe/`, its owner profile written `needs_consent` by
`ungranted.exs`), and a confirmation prompt, by another session of the
person asking for a credential entry. The proof asks `run.sh` for the
server's part through its output directory (`ask-N.json`, answered
`answer-N.json`), and opens each prompt after the browser's activation
window has passed since the click, so what the frame asks for over the
prompt has no gesture behind it. While a modal prompt is open the system
layer hides every frame (`visibility: hidden`, by a stylesheet it owns,
and `inert`, which it removes again only where it added it); on a
fullscreen page it leaves fullscreen first and hides the frames once they
have seen the exit, since a frame hidden before then keeps its fullscreen
and takes it back, with no gesture, when it is shown again.

## Pointer lock: a limitation, recorded

No document can release a pointer lock another frame holds. Hiding a frame
ends its lock in Chromium, but a frame still holding its person's
activation (about five seconds after a click) asks again and gets the
pointer back while it is hidden behind the prompt it opened
(`pointer_lock_retaken`). What holds instead, and the attempt asserts:
the frame is hidden and inert, so it cannot draw over the prompt, take its
input or act on it; focus is in the prompt, which Tab moves within and
Escape operates; Escape, as the browser reads the person's key, ends the
lock, and the frame's next ask is refused without a new gesture; and
nothing the frame tries — asking for another prompt, posting to the
shell, keys of its own, reaching the shell's document — confirms or
dismisses the prompt, and a confirmation needs a fresh proof a frame
cannot give. Only a frame whose grant holds the `pointer_lock` capability
is framed with `allow-pointer-lock` (`Compendium.Tincture.Rules`), so only
such a frame can do this. Escape is sent through Chromium's DevTools
protocol, since Playwright's own key press does not reach the browser's
end of a pointer lock; the attempt runs in Chromium alone.

Chromium's attempts run in its full build, as the harness launches it
elsewhere (`launchBrowser`), not in the headless shell the rest of the
proof runs in: the headless shell keeps a hidden frame's pointer lock,
where Chrome and the full build release it as the frame is hidden.

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
| `grant_prompt_fullscreen` | refused | a grant prompt opened over a frame that holds fullscreen and pointer lock is shown, modal in the top layer, only once every frame is hidden and inert and the page left fullscreen; while it shows the frame holds no pointer lock and the page is not fullscreen, and once it closes the frame, shown again, takes back neither without a new gesture |
| `confirmation_prompt_fullscreen` | refused | the same for the confirmation prompt of a change another session of the person asked for |
| `pointer_lock_retaken` | disclosure | a frame that opens a credential prompt inside its person's gesture takes the pointer back while hidden behind it (recorded, a limitation); it is hidden and inert, focus is in the prompt, which Tab and Escape operate, Escape ends the lock for good, and nothing the frame does confirms or dismisses the prompt |
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
| `suspended_on_another_member` | an action after the frame was suspended on another member: a browser cell runs one member on SQLite, so the cluster suite proves it (`apps/cyfr/test/cluster/frame_suspension_test.exs`): a frame suspended on one member is refused at its credential's next use on the other, with the control channel up and with it cut |

## Record

Recorded on 2026-10-01 on `p1` (`tests/browser/README.md`) by `run.sh`, each
cell private / public; the prompts over the fullscreen frame are one cell
each, Chromium's in its full build.

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
| `grant_prompt_fullscreen` | held | not applicable: the headless build granted the frame no fullscreen from a click | not applicable: as for Firefox |
| `confirmation_prompt_fullscreen` | held | not applicable: as above | not applicable: as above |
| `pointer_lock_retaken` | held; the frame held the pointer over the prompt (lost it 3 times, took it 4); focus in the prompt and moved by Tab; the frame's six tries changed nothing; Escape ended the lock and its next ask was refused (`SecurityError`); a second Escape dismissed the prompt, the frame told it closed unsaved | not applicable: Chromium alone | not applicable: Chromium alone |

Real Firefox is not verified: the harness's headless Firefox grants a
frame no fullscreen from a click, so whether a real Firefox releases a
hidden frame's pointer lock, as Chrome does, has not been driven here.

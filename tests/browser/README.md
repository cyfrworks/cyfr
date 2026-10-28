# The browser harness

The harness starts `cyfr` releases as `tests/release-boot/` starts one
(`tests/release-boot/release.sh`), on SQLite unless a proof names
PostgreSQL, and drives them from every browser the official Playwright
image ships. Its shell side is `harness.sh`, sourced after `release.sh`;
its browser side is `lib.mjs`, which each experiment imports as
`../browser/lib.mjs`. Every cell is a home, reached over HTTPS, and it
serves a proof in one of two shapes: one cell, the home `cyfr.test`, or
several homes, each a cell on a hostname of its own. The proofs start no object store; a
cell keeps its storage on its own disk. The S3 checks run against the
MinIO image `.github/workflows/test.yml` pins by digest, in its `s3-minio`
job's "Start MinIO" step.

The harness is JavaScript. The Playwright images carry the browsers but not
Playwright's library: the Python image's `playwright` wheel ships a Node
driver binary, while `playwright-core` from npm is JavaScript alone and
runs on the image's own Node. `package-lock.json` pins it with its
integrity hash, and `npm ci --ignore-scripts` installs it once per
lockfile, into a cache under `_build/browser-node-modules/<hash>` keyed by
the SHA-256 of `package-lock.json` and the image, so no binary is fetched
at test time. `playwright_run` (`harness.sh`) runs an experiment in the image,
pinned by digest, on the host's network, with `--shm-size=1g`, since
Chromium and Firefox keep their shared memory in `/dev/shm`, whose Docker
default of 64 MB is too small. It mounts the cache read-only at
`/node_modules`, and `apps/cyfr/assets` read-only at `/assets` for an
experiment that loads the console's own modules (`tests/markdown-proof/`).

A proof asks its `run.sh` for the server's part of a step through its
output directory: `ask()` (`lib.mjs`) writes `ask-N.json` and waits for
`answer-N.json`, and the loop that answers it is `harness.sh`'s, which
removes each ask file once it has answered it.

The transport self-check runs with
`scripts/heavy-check.sh -- node --test tests/browser/lib-test.mjs`.
It exercises peer resets with local listeners and is also part of
`tests/release-boot-test.sh`, the release proofs' shared CI check.

**Redaction.** Every proof redacts with the one redaction `lib.mjs`
exports (`redact`, `redactFrames`, `recordText`, `pageTokens`, `MARKER`).
A known secret, a value under a secret-named key or attribute, and a
bearer become `[secret]`; an asset credential becomes `/_s/[credential]`
or `/_c/v1/[credential]`; an `SFMyNTY.` signed token becomes
`[signed token]`.

## One cell: `https://cyfr.test`

`run.sh` starts the release as the home `cyfr.test` (`browser_cell`),
signs a person in (`tests/release-boot/fixture.exs`), publishes the two
tinctures under `tinctures/` publicly in that person's athanor, grants
`frame-probe` as that person (the fixture's `grant`: a tincture's frame
opens only under its owner's grant), and runs `frame-facts.mjs` against
it. The person's layout names no canvas
(`browser_picker_layout`), so the shell runs none and draws the picker
the frame experiments launch from; canvases are the canvas proof's
(`tests/canvas-proof/`). The tincture, containment and
canvas proofs (`tests/tincture-proof/`, `tests/hostile-frame-proof/`,
`tests/canvas-proof/`) use the same shape; [The proofs](#the-proofs) lists
every proof and its shape.

`browser_cell` makes the run's authority when the run has none and the
home as `browser_home` makes every home (below), and issues a certificate
for the attacker's name, `attacker.test`, beside it (`browser_attacker`).
Every browser reaches the cell at `https://cyfr.test` through the
harness's proxy and its front (`startProxy`), and the attacker's receiver
at `https://attacker.test` through the same front, which hands the
receiver each request as the browser sent it, or at `http://attacker.test`.
The site's origin is secure, so every browser names each request's
destination (`sec-fetch-dest`) to it, and an attempt at the attacker's
origin is refused by the frame's policy, never as mixed content.

## Homes: several cells on several hostnames, over HTTPS

A home is a cell started on a hostname of its own (`browser_home`, and
`release.sh`'s `cell_hostname`): the public home `cyfr init --access public
--domain HOST` makes (`CYFR_ACCESS=public`), whose server names that host
(`CYFR_HOST`) and whose public URL, the origin every policy is derived
for, is `https://HOST` (`CYFR_PUBLIC_URL`), both as the command line wrote
them. It runs behind a TLS-terminating front that forwards to its proxy
listener (`CYFR_PROXY_PORT`), the one listener that trusts forwarded
headers, as a public deployment runs behind the stack's Caddy. Each home
has its own node name and free listener ports picked by
`scripts/lib/run-names.sh`'s `run_names_free_port`. Read the chosen ports
from the cell with `cell_port`, `cell_value CELL CYFR_HOST_API_PORT`, and
`cell_proxy_port`. An explicit `BROWSER_HOMES_PORT` keeps consecutive
three-port ranges for the homes, starting with that port. `server_stop`
stops one cell or all of them.

**Hostnames.** A home's name is a `.test` name, resolved by nothing: the
browsers reach every name through the harness's proxy, which routes each
name to its home itself, so no DNS, `/etc/hosts` or other system
configuration outside the checkout is read or changed. `.test` is reserved
for testing (RFC 6761), no browser exempts it from its proxy, and every
browser treats the unknown top-level label as a public suffix, so
`alpha.test` and `beta.test` are distinct sites, as two homes on the
internet are. `*.localhost` names were not taken: each browser bypasses
its proxy for loopback names differently, and all three treat a
`*.localhost` page as a secure context even over plain HTTP, which would
prove nothing about TLS.

**The authority.** Each run makes its own certificate authority
(`browser_authority`): a P-256 key and a certificate that lives one day and
may vouch for `.test` names alone (a critical name constraint). Its
certificate, the browsers' trust settings, `homes.json` and each name's
certificate and key are in `$WORK/authority`, which the Playwright
container mounts read-only at `/authority`; its private key is in
`$WORK/authority-keys`, which nothing mounts, and goes with the scratch
directory, so it never enters the tree. `browser_certificate` issues a
name's certificate, and `browser_unsigned` routes a name the authority did
not sign: its certificate issued by a second authority, the stranger,
which no browser trusts, or a home's own certificate, which names another
host.

**Trust.** `playwright_run` makes every browser of the container trust the
authority once the run has one; a run without one mounts nothing of it, and
the browsers keep the image's own trust.

| Browser | How it trusts the run's authority |
|---|---|
| Chromium | its full build (`launchBrowser` launches `channel: "chromium"`), which every proof launches, reads the managed policy `CACertificates` from `/etc/opt/chrome_for_testing/policies/managed/`; its headless shell reads no policy, so no proof launches it |
| Firefox | Playwright's build reads the policies file `PLAYWRIGHT_FIREFOX_POLICIES_JSON` names, whose `Certificates.Install` holds the authority |
| WebKit | it verifies against `/etc/ssl/certs/ca-certificates.crt`, which the container mounts as the authority alone, so WebKit trusts nothing else |

**The front.** `startProxy(readHomes())` routes each home's tunnel
to its TLS front, which presents the name's certificate and forwards each
request and WebSocket upgrade to the home's proxy listener with
`X-Forwarded-For`, `-Proto` and `-Host`, as Caddy does. Given a receiver
(`startReceiver`) too, it routes `attacker.test` to the receiver, over
HTTPS and plain HTTP. It answers any other plain-HTTP request 421, and
gets no tunnel to a name it does not route. Its account of each request (`proxy.seen`)
holds the cookies the request carried and the cookies its answer set;
`proxy.refusals` holds each handshake a browser broke off. The proxy
starts only once every home answers its readiness check as its hostname,
and otherwise throws naming each cell that does not; a cell that stops
answering later is named in the 502 the front answers for it.

**What a proof is offered.** `lib.mjs` exports, beside the one-cell
helpers:

| Export | What it is |
|---|---|
| `readHomes()` | the run's homes, unsigned names and attacker's name from `/authority/homes.json` |
| `homeOf(homes, host)` | the home of a hostname, `cyfr.test` unless named |
| `askHome(home, path, headers)` | a GET of a home's cell as the front forwards a browser's request: a check of the server itself |
| `launchBrowser(name, proxy)` | a browser of the matrix through the proxy, trusting the authority |
| `secureContext(page)` | the page's protocol, `isSecureContext`, `crypto.subtle` and a digest made with it |
| `roundTripFragment(page, proxy, from, to)` | the fragment fixture: 16 KiB carried from one home to another and back by top-level navigations the pages make themselves, as a carry travels; intact or not, and whether any request carried it |
| `framedRequest(page, proxy, parent, target, path)` | a page of one home framing a path of another, as the front saw the request |
| `crossedCookies(seen, scripted)` | every request to one host that carried a cookie another host set |
| `virtualAuthenticator(page)` | Chromium's virtual WebAuthn authenticator: resident keys, user verification, presence simulated; `add` gives it a credential another one listed, as a synced passkey reaches another device; Firefox and WebKit offer none to Playwright, so a passkey ceremony is Chromium's |

The front answers the harness's own pages under `/__harness/` on every
home, and no cell serves them: `page`, an empty document under no policy,
and `fragment`, the relay of the fragment fixture.

**The handheld.** Every proof that drives a glass runs its glass's steps
once more in Chromium at a proposed 720×720 CSS-pixel touch viewport,
standing in for the square handheld until a board is chosen.
`handheld.mjs` holds it for them: `HANDHELD`, the context's options;
`measure(page, scope)`, each visible control under 24×24 CSS px, each
visible text under 12 px and any sideways overflow within a screen; and
`unmet(measured)`, the screens that break those checks (WCAG 2.2 AA),
a screen whose scope the page did not hold among them.

## The multi-home smoke

`tests/multi-home-smoke/run.sh` starts two homes on SQLite, `alpha.test`
and `beta.test`, routes `stranger.test` (the stranger's certificate) and
`misnamed.test` (alpha's certificate) to alpha, and checks in Chromium,
Firefox and WebKit:

| Check | What holds |
|---|---|
| home | each home's `/login` answers 200 over HTTPS, is a secure context whose `crypto.subtle` digests, joins its LiveView through the front, and is framed by nothing (`frame-ancestors 'none'`, `x-frame-options: DENY`) |
| unsigned | both unsigned names are refused with a certificate error |
| cookies | in a fresh context, no cookie either home set, by its answer or by its script, reaches the other, and a cookie set for all of `.test` is not stored; each home's session cookie is set and returned to it |
| framed | a frame of either home, from either home's page, is asked with `sec-fetch-dest: iframe` and refused 403 before the session, setting no cookie |
| fragment | the fragment fixture carries 16 KiB from each home to the other and back intact, in three hops, and no request carries it |
| passkey | Chromium alone: the virtual authenticator makes and asserts a passkey on each home, and a home's page is refused (`SecurityError`) a passkey for the other |

It writes `multi-home-smoke.json` and `multi-home-smoke.md` into
`PROOF_OUT` and fails when any check does not hold. `MULTI_HOME_SMOKE_FAULT`
breaks a run on purpose: `unsigned` has the stranger sign `beta.test`, so
every browser refuses beta and the smoke fails; `silent` stops beta's
server before the browsers start, so the run fails naming the cell.

## Run names

A proof names what it makes after its own run: a compose project and the
containers, networks and volumes under it, an image, a container, a
directory under `TMPDIR`. Each puts `PROOF_RUN_PREFIX` before those names,
as do the image suites (`tests/imagesuite.py`) and the release boot
(`tests/release-boot/`). It is empty unless set, so CI and a run by hand
name as before; the commit gate sets it to `cyfr-gate-<pid>-<leg>-`, so
what a proof it killed leaves is the gate's to find and remove by name
(`scripts/commit-gate.sh`).

## The proofs

Every proof the harness serves, with its shape, the browsers it can run
and where the `browser` job of `.github/workflows/test.yml` runs it. The
job is four shards, each a runner of its own (its matrix names each
shard's proofs); a shard runs its proofs in this table's order, its first
release-backed proof building the release and the rest reusing it
(`RELEASE_BOOT_SKIP_BUILD=1`). The grant, instance-entry, approval and
file-offer proofs refuse to build one, so no shard opens with them, and the
markdown proof starts no release. A
passkey ceremony is Chromium's alone, whose virtual authenticator a proof
drives, so a proof that needs one runs its passkey steps in Chromium. Three
browsers run in CI where the engine decides the answer, the frame's rules,
a hostile frame, the homes' isolation and the canvas; elsewhere Chromium
alone. Each
proof's own README holds how to run it and its steps.

| Proof | Directory | Shape | Browsers | In CI: shard; browsers |
|---|---|---|---|---|
| frame facts | `tests/browser/` (`run.sh`) | one home, `cyfr.test` | Chromium, Firefox and WebKit | a; all three |
| markdown | `tests/markdown-proof/` | no release: a page of its own, `markdown.test`, serving the console's markdown hook from `/assets` | Chromium | a; Chromium |
| tincture | `tests/tincture-proof/` | one home, `cyfr.test` | Chromium, Firefox and WebKit (`TINCTURE_PROOF_BROWSERS`) | a; Chromium |
| containment (the hostile frame) | `tests/hostile-frame-proof/` | one home, `cyfr.test`, and the attacker's `attacker.test` | Chromium, Firefox and WebKit; the pointer-lock attempt in Chromium alone | a; all three |
| pairing | `tests/pairing-proof/` | one home, `home.test` | Chromium | c; Chromium |
| multi-home smoke | `tests/multi-home-smoke/` | two homes, `alpha.test` and `beta.test` | Chromium, Firefox and WebKit; the passkey in Chromium | d; all three |
| identity | `tests/identity-proof/` | the homes `a.test`, `b.test`, `c.test`, `c2.test` and `c3.test`, and the directory `dir.test` | Chromium | b; Chromium |
| join | `tests/join-proof/` | the homes `a.test`, `a2.test` and `h.test`, and the directories `dir.test` and `dir2.test` | Chromium; the sign-in at the hub, the carry and a second browser profile in Firefox and WebKit as well (`JOIN_PROOF_BROWSERS`) | b; Chromium |
| grant | `tests/grant-proof/` | one home, `home.test` | Chromium | d; Chromium |
| instance entries | `tests/instance-entry-proof/` | one home, `home.test`; SQLite release decisions, claims and administrator boundary | Chromium, desktop (1280×900) and 720×720 | d; Chromium, both viewports |
| approvals | `tests/approval-proof/` | one home, `home.test`; SQLite grant rows, binding lifetimes and named-account prompt | Chromium, desktop (1280×900) and 720×720 | c; Chromium, both viewports |
| file offers | `tests/file-offer-proof/` | one home, `home.test`; offers, recipient acceptance and actual snapshot readback | Chromium, desktop (1280×900) and 720×720 | c; Chromium, both viewports |
| canvas | `tests/canvas-proof/` | one home, `cyfr.test`, and the attacker's `attacker.test`; SQLite only, no passkey step | Chromium, Firefox and WebKit, desktop (1280×900) and 720×720 | d; all three, both viewports |

Shard d also runs the shipped Caddyfile's HSTS check
(`tests/proxy-hsts/`), which starts no release and no browser. The commit
gate's close (`scripts/commit-gate.sh --close`) runs the four shards one
after another as the job runs them, each step read from the workflow, on
this host's pull of the pinned image.

In CI every proof writes its records under
`$RUNNER_TEMP/proofs/<proof>`, or
`$RUNNER_TEMP/proofs/<proof>/<viewport>` for a proof run at each
viewport, and each shard keeps its record files for 14 days as
`proof-records-<shard>`, whether it passed or not. The three vault proofs
fail their shard when any step fails.
They start no execution worker or model: instance-entry claims count
resolver uses, approval use checks admission and binding decisions, and
the named-account prompt uses the announcement a turn would send. File
acceptance really copies bytes. Their READMEs name the executing
evidence separately; none proves the complete shipped model artifact →
production attachment → local provider composition.

## Browser matrix

The browsers `mcr.microsoft.com/playwright:v1.64.0-noble` ships, pinned as
`mcr.microsoft.com/playwright@sha256:06a9939e57531807f8d5fd76ce44b53165ffb7d7501d87ab10e285c20b1e971f`
in `harness.sh`, driven by `playwright-core` 1.64.0:

| Browser | Version |
|---|---|
| Chromium | 156.0.8078.4 |
| Firefox | 157.0 |
| WebKit | 27.2 |

## What the frame's rules answer

A frame sandboxed without `allow-same-origin` is a `null` origin to every
browser, so every data request it makes is cross-origin and needs an
explicit CORS answer. Under a page policy of `connect-src 'self'`, WebKit
refuses such a frame's fetch of its own asset before sending it: CSP
`connect-src 'self'` does not match the frame's own origin for a
`null`-origin document ("Refused to connect … does not appear in the
connect-src directive"), where Chromium and Firefox send the request with
`Origin: null`. Under a `script-src 'self' 'nonce-…'` with no `worker-src`,
a Worker from a `blob:` URL is refused in all three, and
`WebAssembly.instantiate` throws `CompileError` where `script-src` lacks
`'wasm-unsafe-eval'`. The rules (`Compendium.Tincture.Rules`) therefore
name the site origin in `connect-src` and open blob workers and
WebAssembly; what a frame then may do is the table below.

## Frame facts through the shell

The fixture's person, signed in (`session.exs` signs the session's cookie as
a sign-in's response does), opens `frame-probe` from the Prism shell at
`/a/<athanor>/tinctures` on the site origin. The shell creates the frame as
it creates every frame: the probe declares no capability, so
`sandbox="allow-scripts"`, at the probe's public address, whose document
carries the policy the frame's rules derive
(`Compendium.Tincture.Rules.csp/2`, with `frame-ancestors` and
`connect-src` naming the site origin and a `sandbox allow-scripts`
directive). The probe (`tinctures/frame-probe/probe.js`) makes nine attempts
from inside it. Every browser reaches the server through the harness's proxy
(`lib.mjs`) at `https://cyfr.test`, the home the server is started as
(`CYFR_HOST` and `CYFR_PUBLIC_URL` as `cyfr init` writes them,
`harness.sh`); the proxy answers only the 302s of the redirect attempt (no
tincture route redirects) and forwards the rest as the stack's proxy
forwards it. The document's origin is `null` in all three browsers.

Each browser sees the shell at `/a/<segment>/tinctures` frame
`/t/<segment>/local/frame-probe`, `<segment>` the route segment of the
fixture person's own athanor, as the release fixture answers it. The experiment asserts no outcome:
it fails only when an attempt cannot be observed, and `frame-facts.json`,
written by each run, holds every request, message, CSP report and console
line behind a row. Each column names the browser version the facts were
observed in.

| Attempt | Chromium 156 | Firefox 157 | WebKit 27.2 |
|---|---|---|---|
| self-navigation (`location.assign` to its own page) | allowed: the frame loaded its page again | allowed | allowed |
| fetch of its own asset (`asset.json`) | allowed: sent with `Origin: null`, answered 200, readable (`type: cors`) | allowed, as Chromium | allowed, as Chromium (`connect-src` names the site origin) |
| form POST to its own path | refused: no request; "Blocked form submission … the 'allow-forms' permission is not set" | refused: no request | refused: no request; the same console line as Chromium |
| `postMessage` to the parent | allowed: arrived at the shell's window with `event.origin` `"null"` | allowed, `"null"` | allowed, `"null"` |
| `<script>` from another tincture's path on the origin (`frame-neighbour/neighbour.js`) | allowed: sent with `Origin: null`, ran; no CSP report | allowed, ran | allowed, ran |
| module script of its own (`module.js`) | allowed: sent with `Origin: null` (cors), ran; no CSP report | allowed, as Chromium | allowed, as Chromium |
| Worker from a `blob:` URL | allowed: the worker ran (`worker-src 'self' blob:`) | allowed | allowed |
| `WebAssembly.instantiate` of the smallest module | allowed (`'wasm-unsafe-eval'`) | allowed | allowed |
| fetch of an asset answered 302 to another asset | allowed when the 302 carries `access-control-allow-origin: *` (followed, `redirected: true`, readable); refused when it carries no CORS header; the server's own 302 (`/chat` to `/login`) refused the same way | as Chromium | as Chromium |

What the rows mean for the rules: a sandboxed frame without
`allow-same-origin` is a `null` origin to every browser, so any data request
it makes is cross-origin and needs an explicit CORS answer, and `connect-src`
names the site origin rather than `'self'`; scripts from any path of the
origin run under `script-src 'self'`, another tincture's included; blob
workers and WebAssembly run because the policy opens them; forms are closed
by the sandbox and `form-action 'none'`; messages to the parent arrive with
origin `"null"`, so the shell tells its frames apart by the port it handed
each, never by origin.

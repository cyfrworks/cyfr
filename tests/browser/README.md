# The browser harness and its record

`run.sh` starts the `cyfr` release as `tests/release-boot/` starts one
(`tests/release-boot/release.sh`), on SQLite, under the name `cyfr.test`
(`harness.sh`), signs a person in (`tests/release-boot/fixture.exs`),
publishes the two tinctures under `tinctures/` publicly in that person's
athanor, and runs `frame-facts.mjs` in the official Playwright image
against it. `harness.sh` and `lib.mjs` are shared with the tincture
proof (`tests/tincture-proof/`). The `browser` job of
`.github/workflows/test.yml` runs them.

The harness is JavaScript. The Playwright images carry the browsers but not
Playwright's library: the Python image's `playwright` wheel ships a Node
driver binary, while `playwright-core` from npm is JavaScript alone and
runs on the image's own Node. `package-lock.json` pins it with its
integrity hash and `npm ci --ignore-scripts` installs it, so no binary is
fetched at test time. `apps/cyfr/assets` has no JavaScript toolchain of its
own to share.

This file is the record the end-state plan's slice A2 names: the browser
matrix, the frame facts slice C freezes its rules against, the host the
image suites ran on, and their results.

## Browser matrix

The browsers `mcr.microsoft.com/playwright:v1.63.0-noble` ships, pinned as
`mcr.microsoft.com/playwright@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27`
in `run.sh`, driven by `playwright-core` 1.63.0:

| Browser | Version |
|---|---|
| Chromium | 153.0.8010.12 |
| Firefox | 155.0 |
| WebKit | 26.6 |

## Frame facts the rules were frozen against

The first record: a page the harness's proxy answered on the server's own
origin, where the Prism shell frames tinctures from, held `frame-probe`'s `/t/` page in `<iframe sandbox="allow-scripts">`
as the shell does, and the probe (`tinctures/frame-probe/probe.js`) made
nine attempts from inside it, under the policy the `/t/` route served
before the frame's rules: its CSP was
`default-src 'self'; script-src 'self' 'nonce-…'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'`,
and its assets answer `access-control-allow-origin: *`. Every browser reaches
the server through the harness's proxy under the name `cyfr.test`; the
proxy answers only the framing page and the 302s of the redirect attempt
(no `/t/` route redirects today) and forwards the rest unchanged. The
document's origin is `null` in all three browsers.

Recorded on 2026-09-26 on the host below; `frame-facts.json`, written by
each run, holds every request, message, CSP report and console line behind
a row.

| Attempt | Chromium 153 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| self-navigation (`location.assign` to its own page) | allowed: the frame loaded its page again | allowed | allowed |
| fetch of its own asset (`asset.json`) | allowed: sent with `Origin: null`, answered 200, readable (`type: cors`, the asset's `access-control-allow-origin: *`) | allowed, as Chromium | refused before sending: CSP `connect-src 'self'` does not match the frame's own origin for a `null`-origin document ("Refused to connect … does not appear in the connect-src directive"); nothing reached the server |
| form POST to its own path | refused: no request; "Blocked form submission … the 'allow-forms' permission is not set" | refused: no request | refused: no request; the same console line as Chromium |
| `postMessage` to the parent | allowed: arrived with `event.origin` `"null"` | allowed, `"null"` | allowed, `"null"` |
| `<script>` from another tincture's path on the origin (`frame-neighbour/neighbour.js`) | allowed: sent without `Origin` (no-cors), ran; no CSP report | allowed, ran | allowed, ran |
| module script of its own (`module.js`) | allowed: sent with `Origin: null` (cors), ran; no CSP report | allowed, as Chromium | allowed, as Chromium |
| Worker from a `blob:` URL | refused: CSP `worker-src` falls back to `script-src 'self' 'nonce-…'`; the worker's error event | refused: CSP `worker-src` | refused: CSP `worker-src` |
| `WebAssembly.instantiate` of the smallest module | refused: `CompileError`, `script-src` lacks `'wasm-unsafe-eval'`; CSP report `script-src` | refused: `CompileError` "blocked by CSP"; CSP report `script-src` | refused: `CompileError` naming `'unsafe-eval'` or `'wasm-unsafe-eval'`; no CSP report event |
| fetch of an asset answered 302 to another asset | allowed when the 302 carries `access-control-allow-origin: *` (followed, `redirected: true`, readable); refused when the 302 carries no CORS header; the server's own 302 (`/chat` to `/login`) refused the same way, neither answer carrying the header | as Chromium | refused before sending, all three: CSP `connect-src`, as the plain fetch |

What the rows mean for rules frozen against them: a sandboxed frame without
`allow-same-origin` is a `null` origin to every browser, so any data request
it makes is cross-origin and needs an explicit CORS answer, and WebKit
refuses it earlier still through `connect-src 'self'`; scripts from any path
of the origin run under `script-src 'self'` in all three, including another
tincture's; `worker-src` and WebAssembly are closed by today's `script-src`;
forms are closed by the sandbox; messages to the parent arrive with origin
`"null"`, so the parent cannot tell one frame from another by origin.

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
(`lib.mjs`) under the name `cyfr.test`, which the server is started with
(`CYFR_HOST` and `CYFR_PUBLIC_URL`, `harness.sh`); the proxy answers only the
302s of the redirect attempt (no tincture route redirects) and forwards the
rest unchanged. The document's origin is `null` in all three browsers.

Recorded on 2026-09-26 on the host below, each browser seeing the shell at
`/a/@release-proof/tinctures` frame `/t/@release-proof/local/frame-probe`;
`frame-facts.json`, written by each run, holds every request, message, CSP
report and console line behind a row.

| Attempt | Chromium 153 | Firefox 155 | WebKit 26.6 |
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

## Host

The verification host of this record:

| Fact | Value |
|---|---|
| Name | `p1` |
| System | Ubuntu 26.04.1 LTS, kernel 7.0.0-34-generic, 16 cores, 60 GiB |
| Docker | Engine 29.1.3, cgroup v2, Compose 2.40.3 |
| `user.max_user_namespaces` | 249429 |
| `kernel.apparmor_restrict_unprivileged_userns` | 1 (unprivileged user namespaces are confined by AppArmor) |
| `kernel.unprivileged_userns_clone` | 1 |
| Container to host | refused: ufw is enabled with its default INPUT policy, so a container cannot reach a listener on this host through the bridge gateway |

Because of the last row the worker-runners suite, whose scripted control
plane listens on the host, ran on a Docker-in-Docker host on `p1`: the
`docker:29-dind` image (inner engine 29.8.1, cgroup v2, `cgroupfs` driver)
in a privileged container, same kernel and so the same user-namespace
settings, whose containers reach a listener inside it through the inner
bridge.

## Image suites and acceptance runs

Run on `p1` on 2026-09-26 against images built from this tree
(`Dockerfile.locus`, `Dockerfile.opus`, `Dockerfile`), each as
`.github/workflows/test.yml` invokes it; counts are the suites' `ok:` lines.
The Trivy scans of those jobs were not run here.

| Suite | Result |
|---|---|
| builder-image: `scripts/builder-smoke.py` | pass, 22 |
| builder-image: `isolation.py` (A1's V1 renames) | pass, 34 |
| builder-image: `memory.py` | pass, 41 |
| builder-image: `headroom.py` | pass, 11 |
| locus-backends-image: `e2e.py`, the scripted controller and `cyfr` as the controller | pass, 83 |
| locus-backends-image: `isolation.py` (A1's V1 renames) | pass, 92 |
| locus-backends-image: `refusals.py` | pass, 35 |
| locus-backends-image: `residue.py` | pass, 29 |
| locus-backends-image: `memory.py` | pass, 25 and 26 in two runs (its status polls print a line each) |
| worker-image: `runners.py` (A1's E1 egress cases), on `p1` | fail after 8: the pinned-egress case's guest cannot reach the harness's listener (the ufw row above) |
| worker-image: `runners.py`, on the Docker-in-Docker host | 86 pass, including every pinned-egress, kill, taint, stream, late-child and control-plane-cut case; then fail: after the case that kills the service's VM, the restarted container's cyfr-keeper reports "memory bounds are unavailable … processes remain in /sys/fs/cgroup" and starts no runner, so the pool never refills and the memory cases after it do not run. A harness artefact: the case polled the container with `docker exec` while it restarted in place, and runc's processes entering it for the exec sat in the reused cgroup root, in the host's pid namespace, when the new keeper drained it, listed there as pid 0. The case now lists processes from the host (`docker top`) across the restart, and the keeper's drain skips an entry of another pid namespace and waits between its passes |
| worker-image: `runners.py` and `namespace.py`, native engine, harness in a container on a shared network | pass: 172 and 28, the service-death case and the restart step among them |
| browser: `run.sh` | pass, every attempt observed in every browser |
| tincture proof: `tests/tincture-proof/run.sh` | pass in every browser (its README holds the record) |
| release-boot: `boot.sh sqlite`, with the backup round trip | pass |
| release-boot: `boot.sh postgres`, with the backup round trip | pass |
| s3-minio: `--only s3_integration` against `pgsty/minio` (RELEASE.2026-08-04T00-00-00Z) | pass, 35 of 35 |
| `scripts/test-partitioned.sh -n 4 -a sqlite apps/cyfr/test` | 5259 of 5260; the one failure is the resolver-dependent `nonexistent.test` case of `Opus.HttpHandlerEnforcementTest`, which fails on this host on every tree; no new ownership line |
| the same on PostgreSQL (`_build/test_pg`) | 5259 of 5260, the same one failure; no new ownership line |

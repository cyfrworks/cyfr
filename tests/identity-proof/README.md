# The identity proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a person
enrolls an identity with two printed kits, rotates its live key, and
brings it back from a kit onto a fresh installation, and that each home
involved sees what it should and nothing more. Every home is a `cyfr`
release on a SQLite cell of its own, on a `.test` name behind the
harness's TLS front (`browser_home`), since passkeys and the glass's
WebCrypto key need a secure origin:

| Cell | Name | Configured |
|---|---|---|
| the directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer`: the one writer of the identity's log |
| A | `a.test` | the person's home; `CYFR_DIRECTORY_URL=https://dir.test` |
| B | `b.test` | a relying home holding only a directory cache; `CYFR_IDENTITY_FRESHNESS_SECONDS` short (20, `IDENTITY_PROOF_FRESHNESS`) |
| C | `c.test` | empty, `CYFR_RESTORE_TOKEN` of its own, `CYFR_REAUTH_SECONDS` short (20, `IDENTITY_PROOF_REAUTH`), and at first `CYFR_MAX_ATHANORS=1` over one athanor no person owns |
| C2, C3 | `c2.test`, `c3.test` | empty, each with a `CYFR_RESTORE_TOKEN` of its own |
| the thief | `thief.test` | a copy of A's whole cell, taken while A was stopped: no home of the browsers |

## How the homes reach the directory

The browsers reach every home through the harness's proxy. The homes'
own directory client speaks HTTPS to the URL an identity names,
`https://dir.test`, through Sanctum's pinned egress, and the harness
resolves no name. So this proof adds, in pieces another proof sources
(`tests/join-proof/` among them):

- `front.sh` and `front.mjs` — each directory a proof runs is declared
  by its name and its front's address (`identity_directory dir.test
  127.77.0.1`; this proof runs one, the join proof two). Each front is
  one container of the pinned Playwright image per run and directory,
  `cyfr-identity-front-<pid>-<name>`, on the host network as root so it
  can listen on port 443 of its own loopback address, presenting the
  certificate the run's authority issued for its name and forwarding to
  its directory cell as Caddy forwards. Its control listener (port 9443
  of that address) breaks the directory on purpose
  (`identity_front_fault NAME MODE`): `down`, `drop-recover` (a recovery
  forwarded, its answer never delivered) and `block-reads-after-recover`
  (once a recovery is answered, every read of a log closed unanswered),
  and reports every request that reached it (`identity_front_seen NAME`).
- `cells.sh` — each home's deployment file gains `ERL_INETRC` (an inetrc
  of the run's own naming every declared directory at its front's
  address), every front's address in `CYFR_PRIVATE_EGRESS_TARGETS`, and
  `CYFR_DIRECTORY_URL`, the one directory it enrolls at
  (`identity_reaches_directory CELL NAME`); once its server answers, the node takes the run's
  authority as its trusted store (`:public_key.cacerts_load/1` over
  `bin/cyfr rpc`), as an operator adds a certificate authority to a
  node's store. No test seam is set in any release. It also holds the
  thief's copy, a hard kill of a cell (`identity_kill`), restore posts
  made as the browser makes them, and `identity_fixture`, which evaluates
  `fixture.exs` inside a running cell.

No DNS, `/etc/hosts`, trust store or other configuration outside the
scratch directory is read or changed. Everything the run starts — the
cells' servers, the fronts, the Playwright container — and the scratch
directory, with the run's authority key, every token and every kit line,
is removed when it ends, whether it succeeds or fails.

## Chromium alone

The person's passkeys are made and used by Chromium's virtual WebAuthn
authenticator over CDP (`virtualAuthenticator`); Firefox and WebKit offer
Playwright none, so the proof runs in Chromium alone. The glass's steps run
once more on a second glass at the proposed handheld's 720×720 touch
viewport (`tests/browser/handheld.mjs`).

## Steps

`proof.mjs` drives the browser; `run.sh` answers its asks for the homes'
part (`ask-N.json`, answered `answer-N.json`), and an ask or answer that
carried a kit line or a token is deleted once read. Each step is one row;
the proof stops at the first row a later one rests on.

| Step | What holds |
|---|---|
| `passkey` | the person's first passkey at A, registered from the settings page through the system layer's `webauthn:create` ceremony |
| `pair` | before any enrollment, a glass pairs locally at A from the shell's Devices, under a local subject, with no directory |
| `enroll` | enrolled from the settings page: the form names the pinned directory and says what its loss, the loss of every kit and a recovery mean; the seed the browser drew, confirmed with the passkey, prints its three lines in the system layer; saving the kit erases it from the page; no kit line reaches the browser's storage, an address or any request the proxy saw |
| `second_kit` | another kit, signed by the first one's secret typed into the prompt, drawn in the browser, for the same identifier |
| `rotate` | the live key rotated under a fresh confirmation: A's head and live key move; the glass's certificate signed under the replaced key, presented with a proof of its device key, is refused `4408`; the glass reconnects, renews by its device key and stands under a new certificate |
| `cache` | B, which holds nothing of the person's, reads the identity at its directory from its genesis and caches A's head |
| `reserved` | C refuses its first door sign-in, the operator's own address included, before any kit is presented: `restore_reserved` |
| `claims` | C's own token alone opens it: C2's token is refused `401`, an identity the directory never saw `422`, a seed that is no kit of the identity `422`, and no attempt is opened |
| `phases` | C killed (its node signalled, no stop of its own) at `submitted` (the recovery's reply dropped by the front), at `accepted` (the head it must read again unread) and at `minted` (its athanor refused by the cap), and started again each time, resumes under the same request; the directory holds one recovery |
| `replay` | the recovery's request sent again by C answers its recorded outcome, the entry C records once it resumes |
| `thief` | a thief rotating on the copy of A at the same moment as the recovery loses: the recovery's keys hold, and a rotation after it is refused |
| `restore` | the person restores on C in a fresh browser profile from the second kit's three lines and C's token; the form forgets both |
| `b_observes` | B, polled every two seconds from the moment the head moved, serves C's new head within its freshness bound, give or take the one poll that saw it (6 s) |
| `window` | the restore session's first-method window does not slide with use: past it, with the settings page used throughout, no first passkey registers; the kit proven again under a new challenge (`/restore/challenge`, `/restore/reproof`) opens a new window |
| `first_passkey` | the restored person's first passkey at C |
| `door` | a GitHub door linked at C under a fresh confirmation with that passkey, its link ticket minted as a completed sign-in with the door leaves one (no identity provider is reachable) |
| `pair_again` | C holds no paired client of the person; the glass opening C's page holds no device there |
| `viewport` | the glass's steps once more at 720×720: a second glass paired locally at A beside the first, before any enrollment, under a local subject; reconnected at A after the rotation under a renewed certificate; and opened at C, which holds no device of it; each of those screens has every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA) |
| `without_a` | with A and its copy stopped, the person restores on C3 from the second kit |
| `without_a_reach` | that restore reached the directory alone: every request at the front is a directory path, and A answers nothing |
| `superseded` | C2's recovery from the first kit, accepted with its head left unread, is replaced by C3's; C2 resumed ends `superseded`, its staged keys gone, no person minted |
| `b_observes_again` | B, its head verified just before C3's restore, serves C3's head within its bound of that verification, give or take the one poll that saw it, with A gone |
| `directory_down` | with the directory down, B serves the head it verified within its bound and pauses past it (`identity_stale`) |

What this proof does not cover is J.J3's: admitting the person at another
home through the CYFR door, and retiring the sessions a relying home
minted. An externally operated directory is not provided: the directory
here is a disposable writer the run starts, which proves no hosted
service.

## Record

Recorded on 2026-10-03 on `p1` by `run.sh`, Chromium 153.0.8010.12, B's
bound 20 seconds and C's first-method window 20 seconds: every step held.

| Step | What the record shows |
|---|---|
| `passkey`, `first_passkey` | one credential for the home's RP ID, registered active |
| `pair` | a local subject, the person still unenrolled |
| `enroll`, `second_kit` | the three statements shown; the kit drawn in the prompt and gone from the page once saved; no kit line in storage, an address or any request (0 leaks) |
| `rotate` | head and live key moved; the replaced certificate closed `4408`; the glass sent `connect`, was closed `4408`, sent `renew` and `proof`, and holds a new certificate |
| `reserved`, `claims` | `restore_reserved`; `401`, `422`, `422`, no attempt opened |
| `phases` | `503` at `submitted`, `accepted` and `minted`, the attempt at that phase each time; one recovery added to the log (`genesis, recover, rotate, recover`: the first `recover` is the added kit) |
| `replay` | the same entry hash as the one C recorded on resuming |
| `thief` | both of the thief's rotations refused `stale_head`: launched with the restore's post, the recovery reached the directory first in this run. A rotation that lands first is replaced by the recovery all the same: `Sanctum.DirectoryTest`'s "a rotation landing between a recovery's read and its write re-bases it on the new head" |
| `restore`, `without_a` | completed in one post each, the form emptied; with A and its copy stopped, every request at the front a directory path |
| `b_observes`, `b_observes_again` | 16 s after the head moved; 21 s after B last verified, against a bound of 20 and one two-second poll |
| `window` | past the window, the passkey refused with its sentence; the reproof completed |
| `door`, `pair_again` | one door linked; the restored person holds no paired client at C, and the glass is unpaired there |
| `viewport` | at 720×720 the second glass paired under a local subject, stood again at A under a renewed certificate after the rotation, and was unpaired at C; its three screens had no control under 24×24 CSS px, no text under 12 px and no overflow |
| `superseded` | `409 superseded`, its staged keys gone, no person on C2 |
| `directory_down` | the verified head served within the bound; `identity_stale` past it |

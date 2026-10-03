# The join proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a person
whose keys are at their own home joins a hub as a member: they sign in
there with their CYFR identity, pair a phone there under their home's
certificate, and keep or lose that standing as removal, rotation,
recovery and an unreachable directory say they should. Every home is a
`cyfr` release on a SQLite cell of its own, on a `.test` name behind the
harness's TLS front (`browser_home`), started from the shipped release's
environment, so its cookie, CORS and frame settings are production's:

| Cell | Name | Configured |
|---|---|---|
| the person's directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer` |
| the hub's directory | `dir2.test` | `CYFR_DIRECTORY_SERVE=writer`: a second, independently configured directory |
| A | `a.test` | the person's home; enrolls at `dir.test`; `device_cert_seconds` short (40, `JOIN_PROOF_CERT_SECONDS`), so a phone renews there while the proof runs |
| H | `h.test` | the hub; enrolls its own people at `dir2.test`; `CYFR_IDENTITY_FRESHNESS_SECONDS` short (20, `JOIN_PROOF_FRESHNESS`) |
| A2 | `a2.test` | empty, with a `CYFR_RESTORE_TOKEN` of its own: where the person restores once A is lost |

The cells reach both directories through the identity proof's fronts
(`tests/identity-proof/front.sh` and `cells.sh`, one front per
directory, on `127.77.0.1` and `127.77.0.2`); every cell can resolve
either name, and each enrolls at its own. No DNS, `/etc/hosts`, trust
store or other configuration outside the scratch directory is read or
changed. Everything the run starts, the cells' servers, the fronts and the
Playwright container, and the scratch directory, with the run's
authority key, every token, cookie and kit line, is removed when it ends,
whether it succeeds or fails.

## Browsers

Every step runs in Chromium, the glass's steps once more at a 720×720
touch viewport. The person's passkeys are made and used by Chromium's
virtual WebAuthn authenticator over CDP, one credential copied between
the authenticators of the person's browsers as a synced passkey is, its
counter carried along so no home sees it fall. Firefox and WebKit offer
Playwright no virtual authenticator, so they run the sign-in at H, the
carry between the homes and a second fresh profile: they are signed in at
A by the release fixture's door, after the carry's fragment has reached
A's sign-in page, and each fresh confirmation the carry needs at A is
given on a glass paired at A in Chromium, which reads the pending
request from A's record and confirms it with the person's passkey. Each
browser's requests between the homes are held to `cross-site` in its own
`cross_site` row; every other step is recorded as Chromium only. In-app
browsers and mail clients that rewrite links are not covered.

## Steps

`proof.mjs` runs the sign-ins (`common.mjs`) and `steps.mjs` the rest;
`run.sh` answers their asks for the homes' part (`ask-N.json`, answered
`answer-N.json`), and an ask or answer that carried a cookie, a token, a
kit line or a confirmation's secret is deleted once read.

| Step | What holds |
|---|---|
| `home` | the person enrolls at A from the settings page with a passkey, adds a second printed kit (`person/enroll_holder`), and pairs a glass at A |
| `hub` | H, enrolling its own people at `dir2.test`, allows the person's identifier at its door and invites it to a group athanor and a pair athanor |
| `sign_in` | a fresh profile with no saved homes opens H by its address and names A; A's `/carry` is reached through A's sign-in with the carry's fragment kept, the person begins there, both homes show the same code, A's confirmation names it, and H admits once, making them a member of both athanors; every cross-home request is `cross-site`; neither origin's storage holds a list of homes |
| `resolution` | H read the person at `dir.test`, which their genesis names, and nothing of them at its own `dir2.test`; neither home's database has a table of visited homes |
| `second_profile` | another fresh profile signs in by entered address the same way, importing nothing of the first |
| `crafted` | a crafted carry link at A or H writes nothing: no action, confirmation, receipt or session |
| `copied_session` | a copy of the person's session at A, in a browser holding none of their passkeys, obtains no assertion for H (A asks for a fresh proof it cannot give, which the person's own glass shows), and is no session at H |
| `dropped_callback` | H's callback, committed, its answer never delivered: the browser's retry is answered with the session H made, never a second admission |
| `closed_hops` | a tab closed after the carry began, after H's challenge reached A, and after A's assertion was made: a new tab resumes, and each ends in one admission |
| `forged_completion` | a return no home sent, saying `admitted`, writes no membership, admission or saved address at either home |
| `h_passkey` | a passkey the person registers at H from a CYFR-door session waits: signing in with it admits nobody; H's operator authorizes that exact registration with a fresh proof of their own, and only then is it active |
| `a_passkey_at_h` | a passkey scoped to A signs nobody in at H |
| `phone` | a phone opens H's pairing code, keeps the code while the person certifies its key at A under a fresh confirmation there (`/carry#certify=`), comes back with A's certificate and pairs at H; A records the certification |
| `renewal` | at half its life the phone renews its certificate at A by `fetch` from H's `/pair` (`POST /certify/v1/renew`), proving its device key, with no cookie and no confirmation, `cross-site`, and connects to H under the replacement |
| `thread` | the person posts in the pair athanor's thread at H, and it reads there |
| `removal` | removed from H's group athanor, the person can no longer act there, while the pair athanor, the phone paired there and A stay usable |
| `rotate` | after A rotates the live key, H retires the person's sessions bound to the old `key_epoch` within its bound; their H passkey stays and signs them in; a new passkey from a CYFR-door session asks for a fresh proof |
| `recertify` | H refuses the phone's certificate chained to the old key (`4408`), A refuses its renewal (the certification ended), and the phone, offering A's address, is certified there again under a fresh proof, naming A's new `key_epoch` |
| `tabs` | a sign-in begun for H in one tab of A stays bound to H while other tabs work at H and A |
| `lost_home` | with A stopped for good, the person's page at H and the phone paired there go on, bound to H |
| `restore` | the person restores on A2 from the second kit's three lines and A2's installation token, and registers their first passkey there |
| `retired` | H retires every session bound to the old keys, the H passkey's session included, within its bound of reading the recovery; the old H passkey is revoked and signs nobody in; the confirmation waiting at H is voided; an assertion of the old home replayed at H admits nobody; the person signs in at H naming A2 |
| `admin_again` | their next passkey at H waits again for a new authorization by H's operator |
| `viewport` | at the proposed handheld's 720×720 touch viewport in Chromium (`tests/browser/handheld.mjs`): a phone pairs at H under A2's certificate, reconnects, goes to A2 and back, and is revoked, the revocation's request shown on its glass first; the glass's screens, that request among them, the certify panel and the consent prompt read and confirmed in A2's system layer have every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA); a console page of A2 visited on the way is measured and recorded, not held |
| `directory_down` | with `dir.test` down, H keeps the person's work within its bound and pauses protected work past it (`identity_stale`): the person's page at H lands on the sign-in page, which says why; the same session's page works again once the directory answers |
| `cross_site` | every request one home received from another home's page, in every browser and step, carried `sec-fetch-site: cross-site` |

An externally operated directory is not provided: both directories here
are disposable writers the run starts, which prove no hosted service.

## Record

Recorded on 2026-10-03 on `p1` by `run.sh`, against the SQLite `cyfr`
release 0.5.8 built from this tree, in the harness's Playwright image
(`v1.63.0-noble`, pinned by digest in `tests/browser/harness.sh`):

| Step | Chromium 153.0.8010.12 | Firefox 155.0 | WebKit 26.6 |
|---|---|---|---|
| `home` | held | Chromium only | Chromium only |
| `hub` | held | Chromium only | Chromium only |
| `sign_in` | held | held | held |
| `resolution` | held | Chromium only | Chromium only |
| `second_profile` | held | held | held |
| `crafted` | held | Chromium only | Chromium only |
| `copied_session` | held | Chromium only | Chromium only |
| `dropped_callback` | held | Chromium only | Chromium only |
| `closed_hops` | held | Chromium only | Chromium only |
| `forged_completion` | held | Chromium only | Chromium only |
| `h_passkey` | held | Chromium only | Chromium only |
| `a_passkey_at_h` | held | Chromium only | Chromium only |
| `phone` | held | Chromium only | Chromium only |
| `renewal` | held | Chromium only | Chromium only |
| `thread` | held | Chromium only | Chromium only |
| `removal` | held | Chromium only | Chromium only |
| `rotate` | held | Chromium only | Chromium only |
| `recertify` | held | Chromium only | Chromium only |
| `tabs` | held | Chromium only | Chromium only |
| `lost_home` | held | Chromium only | Chromium only |
| `restore` | held | Chromium only | Chromium only |
| `retired` | held | Chromium only | Chromium only |
| `admin_again` | held | Chromium only | Chromium only |
| `viewport` | held | Chromium only | Chromium only |
| `directory_down` | held | Chromium only | Chromium only |
| `cross_site` | held | held | held |

What the run measured:

- Every sign-in admitted once, with the same code shown at both homes;
  in Firefox and WebKit A's confirmation was given on the Chromium glass.
  No origin's storage held a list of homes; Firefox kept two keys in A's
  `localStorage`, `/carry-consecutive-reloads` and
  `/login-consecutive-reloads`, which are LiveView's reload counters.
- H read the person six times at `dir.test` and never at `dir2.test`.
- The phone's two renewals at A answered 200, each after its CORS
  preflight, `cross-site`, with origin `https://h.test` and no cookie.
- H retired the old-key sessions 18.2 s after the rotation and 20 s
  after the restore completed, against its 20 s freshness bound; each is
  observed by loading a page, so it includes up to one page load past the
  moment of retirement, and the steps allow the bound plus 30 s and 40 s.
  What the recovery retired was there to retire: the H passkey, then
  `revoked`, and the pairing its session left waiting, then `voided`.
- With `dir.test` down, H kept the person's work within its bound and,
  asked again 42.1 s after the directory went down, paused protected work
  (`identity_stale`): the person's page at H landed on `/login`, which
  said "Your identity could not be confirmed fresh with its directory
  just now; try again shortly."; the same session's page worked again
  16.2 s after the directory answered.
- Cross-home requests, every one `cross-site`: 101 from Chromium, 16 from
  Firefox, 16 from WebKit.
- At 720×720 the glass's screens, the revocation's request on the glass
  among them, the certify panel and the consent prompt had no control
  under 24×24 CSS px, no text under 12 px and no overflow. A2's page
  visited on the way, measured and not held, had none either.

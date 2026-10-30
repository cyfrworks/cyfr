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
| A | `a.test` | the person's home; enrolls at `dir.test`; a `CYFR_SETUP_TOKEN` of the run's own, under which the person is set up in the browser; `device_cert_seconds` short (40, `JOIN_PROOF_CERT_SECONDS`), so a phone renews there while the proof runs |
| H | `h.test` | the hub; enrolls its own people at `dir2.test`; `CYFR_IDENTITY_FRESHNESS_SECONDS` short (20, `JOIN_PROOF_FRESHNESS`); its operator is the release fixture's first person (`tests/release-boot/fixture.exs` `person`) |
| A2 | `a2.test` | empty, with a `CYFR_RESTORE_TOKEN` of its own: where the person restores once A is lost, from `dir.test`, the directory it is configured with |
| the cyfr.run stand-in | `127.77.0.4`, a port it picks | `tests/registry-stand-in/standin.py --directory https://dir.test`: the `CYFR_REGISTRY_URL` of A, H and A2, its address in each one's `CYFR_PRIVATE_EGRESS_TARGETS`; the person's name is registered there, naming `dir.test` as its directory |

The cells reach both directories through the identity proof's fronts
(`tests/identity-proof/front.sh` and `cells.sh`, one front per
directory, on `127.77.0.1` and `127.77.0.2`); every cell can resolve
either name, and each enrolls at its own. The homes reach the stand-in
by its address over plain HTTP, and nothing of the run reaches cyfr.run.
No DNS, `/etc/hosts`, trust store or other configuration outside the
scratch directory is read or changed. Everything the run starts, the
cells' servers, the stand-in, the fronts and the Playwright container,
and the scratch directory, with the run's authority key, the stand-in's
state, every token, cookie and recovery code, is removed when it ends,
whether it succeeds or fails.

## Browsers

Every step runs in Chromium, the glass's steps once more at a 720×720
touch viewport. The person's passkeys are made and used by Chromium's
virtual WebAuthn authenticator over CDP, one credential copied between
the authenticators of the person's browsers as a synced passkey is, its
counter carried along so no home sees it fall. Firefox and WebKit offer
Playwright no virtual authenticator, so they run the sign-in at H, the
carry between the homes and a second fresh profile: they are signed in at
A by the release fixture's door, a GitHub identity the run links to the
person once they are set up (`fixture.exs` `door`), after the carry's
fragment has reached A's sign-in page, and each fresh confirmation the
carry needs at A is given on a glass paired at A in Chromium, which reads
the pending request from A's record and confirms it with the person's
passkey. Each
browser's requests between the homes are held to `cross-site` in its own
`cross_site` row; every other step is recorded as Chromium only.
`JOIN_PROOF_BROWSERS` names the browsers a run takes, all three unless set;
the `browser` job of `.github/workflows/test.yml` sets `chromium`, so there
Firefox's and WebKit's sign-in at H, carry and second profile do not run,
and the cross-home isolation each engine enforces is the multi-home smoke's
to hold in all three. In-app browsers and mail clients that rewrite links
are not covered.

## Steps

`proof.mjs` runs the sign-ins (`common.mjs`) and `steps.mjs` the rest;
`run.sh` answers their asks for the homes' part (`ask-N.json`, answered
`answer-N.json`), and an ask or answer that carried a cookie, a token, a
recovery code or a confirmation's secret is deleted once read.

| Step | What holds |
|---|---|
| `home` | the person is set up at A through `/setup`'s two screens: `@join-a` typed and found free at the stand-in, a passkey made, the identity registered at `dir.test` and the name claimed, the recovery code read and saved, and A holds that one person, admitted by setup and enrolled under the code's identifier; then they add a second recovery code (`person/recovery_code_add`), approved by the first, and pair a glass at A |
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
| `restore` | the person restores on A2 with the second recovery code and A2's installation token, and registers their first passkey there |
| `retired` | H retires every session bound to the old keys, the H passkey's session included, within its bound of reading the recovery; the old H passkey is revoked and signs nobody in; the confirmation waiting at H is voided; an assertion of the old home replayed at H admits nobody; the person signs in at H naming A2 |
| `admin_again` | their next passkey at H waits again for a new authorization by H's operator |
| `viewport` | at the handheld's 720×720 touch viewport in Chromium (`tests/browser/handheld.mjs`): a phone pairs at H under A2's certificate, reconnects, goes to A2 and back, and is revoked, the revocation's request shown on its glass first; the glass's screens, that request among them, the certify panel and the consent prompt read and confirmed in A2's system layer have every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA); a console page of A2 visited on the way is measured and recorded, not held |
| `directory_down` | with `dir.test` down, H keeps the person's work within its bound and pauses protected work past it (`identity_stale`): the person's page at H lands on the sign-in page, which says why; the same session's page works again once the directory answers |
| `cross_site` | every request one home received from another home's page, in every browser and step, carried `sec-fetch-site: cross-site` |

H's retirements in `rotate` and `retired` are each observed by loading a
page, so each includes up to one page load past the moment of retirement;
the steps allow H's freshness bound plus 30 s and plus 40 s. LiveView keeps
its reload counters in `localStorage` (keys ending `consecutive-reloads`),
which are no list of homes, and `forged_completion` allows A's storage
those keys alone.

An externally operated directory is not provided: both directories here
are disposable writers the run starts, which prove no hosted service.

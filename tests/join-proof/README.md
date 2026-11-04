# The join proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a person
whose keys are at their own home joins a hub as a member: they sign in
there with their CYFR identity, pair a command line there under their
home's certificate, confirm there from their own home, and keep or lose
that standing as removal, rotation,
recovery and an unreachable directory say they should. Every home is a
`cyfr` release on a SQLite cell of its own, on a `.test` name behind the
harness's TLS front (`browser_home`), started from the shipped release's
environment, so its cookie, CORS and frame settings are production's:

| Cell | Name | Configured |
|---|---|---|
| the person's directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer` |
| the hub's directory | `dir2.test` | `CYFR_DIRECTORY_SERVE=writer`: a second, independently configured directory |
| A | `a.test` | the person's home; enrolls at `dir.test`; a `CYFR_SETUP_TOKEN` of the run's own, under which the person is set up in the browser; `device_cert_seconds` short (120, `JOIN_PROOF_CERT_SECONDS`), so a command line at H renews there while the proof runs; 120 rather than the 40 a browser's key once had, since the command line's session at H ends with A's certificate and its confirmation through A, which the `phone` row waits on, takes longer than 40 seconds on a loaded host |
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
whether it succeeds or fails. A failed proof first prints the last
lines of every cell's log (`JOIN_PROOF_LOG_TAIL`, 4000 by default), each
redacted of the cell's own secrets and the run's, so a run whose scratch
directory is gone still names what its cells did; H and A2 log at debug
(`CYFR_LOG_LEVEL`) for that.

## Browsers

Every step runs in Chromium, the cross-home confirmation's steps once more
at a 720×720 touch viewport. The person's passkeys are made and used by Chromium's
virtual WebAuthn authenticator over CDP, one credential copied between
the authenticators of the person's browsers as a synced passkey is, its
counter carried along so no home sees it fall. Firefox and WebKit offer
Playwright no virtual authenticator, so they run the sign-in at H, the
carry between the homes and a second fresh profile: they are signed in at
A by the release fixture's door, a GitHub identity the run links to the
person once they are set up (`fixture.exs` `door`), after the carry's
fragment has reached A's sign-in page, and each fresh confirmation the
carry needs at A is given in Chromium, by a page at A holding the person's
passkey, which reads the pending request from A's record as another
client's and confirms it (`confirmOnPasskeyPage`). A browser holds no
device key of its own: its device is the person's passkey. Each
browser's requests between the homes are held to `cross-site` in its own
`cross_site` row; every other step is recorded as Chromium only.
`JOIN_PROOF_BROWSERS` names the browsers a run takes, all three unless set;
the `browser` job of `.github/workflows/test.yml` sets `chromium`, so there
Firefox's and WebKit's sign-in at H, carry and second profile do not run,
and the cross-home isolation each engine enforces is the multi-home smoke's
to hold in all three. In-app browsers and mail clients that rewrite links
are not covered.

Each press in H's Devices prompt, beginning a pairing or revoking one, waits
until the prompt's dialog is the page's modal top layer and two animation
frames have passed. A canvas frame under the prompt runs in a process of its
own, and Chromium can route a press made sooner to that frame, which then
holds focus while the page hears nothing. A press that lands in a frame is
recorded in the step's `press` or `revoke` and made once more; a second miss
fails the step.

## Steps

`proof.mjs` runs the sign-ins (`common.mjs`) and `steps.mjs` the rest;
`run.sh` answers their asks for the homes' part (`ask-N.json`, answered
`answer-N.json`), and an ask or answer that carried a cookie, a token, a
recovery code or a confirmation's secret is deleted once read.

| Step | What holds |
|---|---|
| `home` | the person is set up at A through `/setup`'s two screens: `@join-a` typed and found free at the stand-in, a passkey made, the identity registered at `dir.test` and the name claimed, the recovery code read and saved, and A holds that one person, admitted by setup and enrolled under the code's identifier; then they add a second recovery code (`person/recovery_code_add`), approved by the first |
| `hub` | H, enrolling its own people at `dir2.test`, allows the person's identifier at its door and invites it to a shared thread, Household, the operator makes through the `shared_thread` tool |
| `sign_in` | a fresh profile with no saved homes opens H by its address and names A in "Sign in from your CYFR"; A's `/carry` is reached through A's sign-in with the carry's fragment kept, the person begins there, both homes show the same code, A's confirmation names it, and H admits once, with their own athanor there and their seat in Household; every cross-home request is `cross-site`; neither origin's storage holds a list of homes |
| `resolution` | H read the person at `dir.test`, which their genesis names, and nothing of them at its own `dir2.test`; neither home's database has a table of visited homes |
| `second_profile` | another fresh profile signs in by entered address the same way, importing nothing of the first; back at H's sign-in page, the field is filled with A from this browser's memory there (`cyfr:sign-in:your-cyfr`) |
| `own_athanor` | the person admitted at H has their own athanor there, where the later steps open their pages and pair their command line |
| `crafted` | a crafted carry link at A or H writes nothing: no action, confirmation, receipt or session |
| `copied_session` | a copy of the person's session at A, in a browser holding none of their passkeys, obtains no assertion for H (A asks for a fresh proof it cannot give, which the person's own Prism at A shows as another client's request, cancelled there), and is no session at H |
| `dropped_callback` | H's callback, committed, its answer never delivered: the browser's retry is answered with the session H made, never a second admission |
| `closed_hops` | a tab closed after the carry began, after H's challenge reached A, and after A's assertion was made: a new tab resumes, and each ends in one admission |
| `forged_completion` | a return no home sent, saying `admitted`, writes no athanor, admission or saved address at either home; H's storage holds only `cyfr:sign-in:your-cyfr` |
| `invited` | an invitation link H's operator makes for a shared thread they make through the `shared_thread` tool, opened in a browser that signs in at A, taken through "Already have a CYFR name? Sign in with it.": H's sign-in page says who invited and never shows the code, the person signs in from A, and H seats them in the thread and states the allow under their identifier anew, naming the invitation; a later sign-in with no link admits them; the link a second time says it can no longer be used |
| `h_passkey` | H's operator, the person H's setup made with a protected device (`tests/release-boot/fixture.exs` `person`), registers their first passkey at H, which the setup device confirms (`device_confirm`); a passkey the person registers at H from a CYFR-door session waits: signing in with it admits nobody; the operator authorizes that exact registration with a fresh proof of their own, and only then is it active |
| `a_passkey_at_h` | a passkey scoped to A signs nobody in at H |
| `terminal` | the real `cyfr` binary, which `run.sh` builds and the step runs on a pseudo-terminal of its own (`script`), reaching the homes through the run's proxy (`terminal.mjs`): `cyfr login --url A` pairs it as the person's device at A, approved under A's Devices; then `cyfr login --url H` shows a new key's code, approved under H's Devices, and the link pasted is answered with what A is to certify; the terminal asks A's address, unlocks its own device at A afresh with its passphrase, draws A's preview of `person.certify` before asking the passphrase once more, and pairs at H with A's certificate (issuer A, audience H, an identity subject), which A records and H holds active, while every request A received in that window came from no browser; in its shell `cyfr whoami` acts at H, and `cyfr pair <digest>` there is confirmed on this command line, H's preview drawn before its passphrase |
| `phone` | the command line paired at H (`terminal`) asks for another device's addition there and waits; the person's browser at H shows that request from H's record as another client's, types A's address under "Confirm at your CYFR" and opens A's `/carry#confirm=` page, which shows the change; confirmed there with a fresh passkey proof, A signs that one record's confirmation and sends the browser to H's `/confirm#home_assertion=`, which H checks against the person's head read fresh, takes as proof `home`, and clears from the address; Enter on the command line repeats its own request, which completes with the pairing link; the same assertion presented at H again confirms nothing |
| `renewal` | past its first certificate's life the command line, unlocking at H again, renews A's certificate at A (`POST /certify/v1/renew`) by a proof of its device key, with no cookie, no browser and no confirmation; the replacement, A's still, for the same key epoch, lives longer, and `cyfr whoami` acts at H under it |
| `thread` | the operator and the person, who share Household at H, have a pair thread there (`shared_thread.pair`); the person posts in it and it reads there |
| `removal` | removed from Household, the person can no longer post there, while the pair thread, their own athanor at H, the command line paired there and A stay usable |
| `rotate` | first a credential entry the person's page at H asks for is confirmed at A under the key about to be replaced, its assertion kept by the proof and never delivered; after A rotates the live key, H retires the person's sessions bound to the old `key_epoch` within its bound; their H passkey stays and signs them in; a new passkey from a CYFR-door session asks for a fresh proof |
| `recertify` | the assertion A made under the old key, presented at H's `/confirm`, confirms nothing, and a request confirmed at A after the rotation goes through; the command line's renewal at A is refused (its certification ended with the old key), and it is certified again at A in the terminal: A's address offered, A's own device unlocked afresh, `person.certify` drawn before its passphrase, and the certificate it keeps names A's new `key_epoch` |
| `tabs` | a sign-in begun for H in one tab of A stays bound to H while other tabs work at H and A |
| `lost_home` | with A stopped for good, the person's page at H goes on, and H holds the command line paired there standing, bound to H |
| `restore` | the person restores on A2 with the second recovery code and A2's installation token, and registers their first passkey there |
| `retired` | H retires every session bound to the old keys, the H passkey's session included, within its bound of reading the recovery; the old H passkey is revoked and signs nobody in; the confirmation waiting at H is voided; an assertion of the old home replayed at H admits nobody; the person signs in at H naming A2 |
| `admin_again` | the command line H holds for the person stands still, though its certificate chains to A's lost keys, and H counts a standing device as a way to confirm: the person revokes it from H's Devices, confirmed through A2 by its assertion, and H holds it revoked; then their next passkey at H waits again for a new authorization by H's operator |
| `viewport` | at the handheld's 720×720 touch viewport in Chromium (`tests/browser/handheld.mjs`), after the restore: a context holding the person's sessions at H and A2 and their A2 passkey asks for a credential entry at H and confirms it through A2's `/carry#confirm=`; H's request panel, A2's confirmation page and its prompt, and H's answer to the assertion have every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA) |
| `directory_down` | with `dir.test` down, H keeps the person's work within its bound and pauses protected work past it (`identity_stale`): the person's page at H lands on the sign-in page, which says why; the same session's page works again once the directory answers |
| `cross_site` | every request one home received from another home's page, in every browser and step, carried `sec-fetch-site: cross-site` |

H's retirements in `rotate` and `retired` are each observed by loading a
page, so each includes up to one page load past the moment of retirement;
the steps allow H's freshness bound plus 30 s and plus 40 s. LiveView keeps
its reload counters in `localStorage` (keys ending `consecutive-reloads`),
which are no list of homes, and `forged_completion` allows A's storage
those keys alone, and H's those keys and the one address its sign-in
page remembers.

An externally operated directory is not provided: both directories here
are disposable writers the run starts, which prove no hosted service.

## The rows before the browser held no key

Until S4 of the devices plan a browser's `/pair` page made a key of its own,
a glass, which a person's home certified for H (`/carry#certify=`). That key
is gone. A remote person's device at H is a command line their home
certifies in the terminal (`terminal`), and a browser confirms for them
there through their own CYFR's assertion. Each row the glass carried is
proven by what replaced it:

| Row then | Proven now by |
|---|---|
| `home` (and pairs a glass at A) | `home`; the confirmations Firefox and WebKit need are given by a page at A holding the passkey |
| `copied_session` (shown on the glass) | `copied_session`: shown in the person's Prism at A |
| `phone` (a glass certified at A pairs at H) | `terminal` (a command line certified at A pairs at H) and `phone` (a browser confirms at H through A) |
| `renewal` (the glass renews at A by `fetch`) | `renewal`: the command line renews at A |
| `removal`, `lost_home` (the glass stays ready) | the command line's client at H stays standing |
| `recertify` (the glass certified again) | `recertify`: an old-key assertion refused, the command line certified again |
| `viewport` (the glass's screens) | `viewport`: the cross-home confirmation's screens |

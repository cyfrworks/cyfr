# The pairing proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a phone
pairs to a home as its glass, confirms on it what a desktop of the same
person asks for, and loses its channel and its certificate when it should.
The home is one `cyfr` release on a SQLite cell, `home.test`, reached over
HTTPS through the harness's TLS front (`browser_home`), since a passkey and
the glass's WebCrypto key need a secure origin. Its device certificates are
made short (`device_cert_seconds`, 20 by default,
`PAIRING_PROOF_CERT_SECONDS`) through the settings operation, as a platform
admin sets one, so the glass renews while the proof runs and a certificate
expires within it.

One person is signed in twice, by the release fixture's door
(`tests/release-boot/fixture.exs` `person`): a desktop context, and a phone
context with a mobile viewport. `proof.mjs` drives both in one Chromium,
and drives the glass's steps once more in a third context, the phone's
session at the handheld's 720×720 touch viewport
(`tests/browser/handheld.mjs`).
`run.sh` builds the `cyfr` command line into the output directory's
`bin/` (removed when the run ends), where the `command_line` step runs it.
It asks `run.sh` for the home's part of a step through its output directory
(`ask-N.json`, answered `answer-N.json`): beginning and completing the
phone's passkey registration through the console's adapter under the
phone's session, and reading the names of the person's vault entries.

## Chromium alone

The phone's passkey is made and used by Chromium's virtual WebAuthn
authenticator over CDP (`virtualAuthenticator` in `tests/browser/lib.mjs`):
a platform authenticator that holds resident keys and verifies its user at
every ceremony. Firefox and WebKit offer Playwright no virtual
authenticator, so they cannot make or use a passkey here, and the proof
runs in Chromium alone.

## Steps

Each step is one row; the proof fails when a row does not hold, and stops
at the first row a later one rests on.

| Step | What holds |
|---|---|
| `passkey` | the phone, signed in to Prism, registers the passkey its authenticator makes, under the first-method rule: a local door's session, signed in moments ago, of a person with no method yet |
| `pair` | the phone's `/pair` page makes its device key first and shows the key's code; the desktop types that code under the shell's Devices and begins a pairing for it; it needs a fresh confirmation, which the phone's Prism shows from the home's record — the change, the code among its preview, and the client that asked — before any proof, and gives with the passkey; the desktop's prompt then shows the pairing link and its QR beside the same code, and no bearer sentence |
| `other_key` | a browser context of its own makes its own key on `/pair` and opens the desktop's link: the home refuses its key as not the one the pairing was approved for, the link leaves its address, and it holds no device; the link still pairs the phone in the next step |
| `glass` | the phone, the browser that showed the code, opens the desktop's link (`invitation_url`, the same link `cyfr pair <code>` prints) and becomes the glass with the key it made: the code leaves the address, the device channel stands under the certificate the pairing answered, and that certificate's key digest is the code the phone showed |
| `confirm` | the desktop asks for a credential entry on its vault page, an API key with no label; the glass shows the home's preview (the change, the entry's name) and the asker before any proof, never the typed value, confirms with the passkey and draws its outcome, confirmed, and the desktop completes the entry |
| `fresh` | a second entry: the first assertion replayed for its record is refused, and the desktop's session asking again alone leaves it waiting with nothing made; the glass's fresh assertion confirms it and the desktop completes it |
| `command_line` | the real `cyfr` binary, which `run.sh` builds and the proof runs beside the browsers, reaching the home through the same proxy and trusting the run's authority, runs `cyfr login`: the desktop opens the link it printed, the link leaves the address and the page shows the code it printed; approved there, the glass shows the record (`session.cli_approve`, the code among its preview) and confirms with the passkey; the binary exits 0 saying who signed in, `cyfr whoami` names the person, the desktop's Devices lists the command line, and once revoked there its session opens nothing |
| `intent` | the device-intent measurement: one discrete intent, `confirmation.pending`, admitted by the gate and dispatched over the device channel, 100 in a row, each timed in the glass's own page from the frame it sends to the answer naming its id |
| `sleep` | the glass sleeps first, then the proof captures its stored certificate and delivered standing; a proof already sent on the old socket is observed until the home answers with standing or closes, and the proof waits past that socket's last received standing expiry plus four seconds (it sends nothing and hears nothing until it wakes) while the desktop asks for a third entry: the home revokes the glass's stream and closes the channel `4408` at the expiry; awake, the glass's first frame on its next connection is `renew`, it sends no intent before its standing, its stream is granted anew, and the third request is shown; its expired certificate, presented with a proof of its key on a connection of its own, is refused `4408`. The observed GitHub sleep failure is consistent with a renewal race, but its record does not prove that cause. |
| `revoke` | the desktop revokes the glass under Devices, confirmed on the glass with the passkey: the home revokes its stream and then the client and closes the channel `4403`, the desktop's list no longer names it, the glass forgets its key and certificate, and its last certificate, presented with a proof of its key, is refused `4403` |
| `viewport` | the glass's steps once more at 720×720, on the phone's session in a context of its own whose authenticator holds the person's passkey: its key's code typed on the desktop, the desktop's pairing read and confirmed in that Prism's system layer, the glass, a credential entry confirmed on it with its outcome drawn, the glass reconnected, and its revocation confirmed on it; the consent prompt and each of the glass's screens have every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA); the Prism page around the prompt is measured and recorded, not held |

The glass's channel is read inside its own page: an init script wraps the
page's `WebSocket` for the device channel alone, records each frame either
way and each close with its code, lets the proof speak as the glass, and
holds what reaches the glass while it sleeps. The same script records each
outcome the glass draws under a prompt as it draws it: a confirmed record
leaves the glass's pending list at its next read, taking the prompt and
its outcome with it, often within the frame that drew them.

The sleep record's `expires_at` comes from the old socket's last received
home standing: the expiry the home armed. A proof sent after its previous standing
is observed through read-only log polling for at most 20 seconds, until a
standing or native close arrives. A renewal with its challenge still held
needs no wait: the glass cannot answer asleep. The stored certificate's
expiry stays beside the home's, with a note when they differ.

The record carries the captured certificate and delivered standing,
the certificate and delivered standing just before
wake, the latest received standing (which may still be held asleep), and
renewal frames (renew, challenge, proof, certificate and standing) seen on
the old socket before sleep. Its old-socket timeline
records every incoming, outgoing and dropped frame by type, stream
revocations and native closes with their codes, plus the sleep and wake
boundaries. Times are milliseconds relative to the captured expiry; a
negative value is before it. Incoming frames say whether the glass was
asleep when they arrived. A gone page records a timeline error without
replacing the step's original failure. Intent arguments and proof signatures
are omitted.

The device-intent measurement is one glass on SQLite, one intent at a
time, in Chromium through the harness's TLS front on a shared host: a
baseline, not a measurement under concurrent load. The record carries its
p50, p95 and p99; no bound is held to them.

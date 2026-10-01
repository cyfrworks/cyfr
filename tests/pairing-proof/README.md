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
context with a mobile viewport. `proof.mjs` drives both in one Chromium.
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
| `pair` | the desktop begins a pairing under the shell's Devices; it needs a fresh confirmation, which the phone's Prism shows from the home's record — the change and the client that asked — before any proof, and gives with the passkey; the desktop's prompt then shows the pairing link and its QR |
| `glass` | the phone opens the desktop's link (`invitation_url`, the same link `cyfr pair` prints) and becomes the glass: the code leaves the address, the device key is made, and the device channel stands under the certificate the pairing answered |
| `confirm` | the desktop asks for a credential entry on its vault page; the glass shows the home's preview (the change, the entry's name) and the asker before any proof, never the typed value, confirms with the passkey, and the desktop completes the entry |
| `fresh` | a second entry: the first assertion replayed for its record is refused, and the desktop's session asking again alone leaves it waiting with nothing made; the glass's fresh assertion confirms it and the desktop completes it |
| `intent` | the device-intent measurement: one discrete intent, `confirmation.pending`, admitted by the gate and dispatched over the device channel, 100 in a row, each timed in the glass's own page from the frame it sends to the answer naming its id |
| `sleep` | the glass sleeps past its certificate's expiry (it sends nothing and hears nothing until it wakes) while the desktop asks for a third entry: the home revokes the glass's stream and closes the channel `4408` at the expiry; awake, the glass's first frame on its next connection is `renew`, it sends no intent before its standing, its stream is granted anew, and the third request is shown; its expired certificate, presented with a proof of its key on a connection of its own, is refused `4408` |
| `revoke` | the desktop revokes the glass under Devices, confirmed on the glass with the passkey: the home revokes its stream and then the client and closes the channel `4403`, the desktop's list no longer names it, the glass forgets its key and certificate, and its last certificate, presented with a proof of its key, is refused `4403` |

The glass's channel is read inside its own page: an init script wraps the
page's `WebSocket` for the device channel alone, records each frame either
way and each close with its code, lets the proof speak as the glass, and
holds what reaches the glass while it sleeps.

## Record

Recorded on 2026-10-01 on `p1` by `run.sh`, certificates of 20 seconds.

| Step | Chromium 153 | What the record shows |
|---|---|---|
| `passkey` | held | registered active under the first-method rule; one credential for `home.test` |
| `pair` | held | the phone's Prism showed `pairing.begin` and "a browser signed in with github" before the proof; the link `https://home.test/pair#code=…` and its QR |
| `glass` | held | the address left at `https://home.test/pair`; `connect`, `proof`, then the stream's open and the pending read |
| `confirm` | held | the glass showed `vault.create` and the entry's name, never the typed value; the entry was made |
| `fresh` | held | the replayed assertion refused (`unauthenticated`); the desktop's repeat left one request waiting and nothing made; a fresh assertion, then the entry |
| `intent` | held | `confirmation.pending`, 100 in a row: p50 2.9 ms, p95 3.2 ms, p99 3.8 ms; an earlier run p50 2.0 ms, p95 2.3 ms, p99 2.6 ms |
| `sleep` | held | woke 4 s past the expiry; its renewal dropped while asleep; the stream revoked and the channel closed `4408`; first frame after waking `renew`, no intent before standing, a new grant, the third request shown; the expired certificate refused `4408` |
| `revoke` | held | `pairing.revoke` confirmed on the glass; the stream revoked, then the client, closed `4403`; no longer listed; key and certificate erased; the last certificate refused `4403` |

The device-intent measurement is one glass on SQLite, one intent at a
time, in Chromium through the harness's TLS front on a shared host: a
baseline, not a measurement under concurrent load.

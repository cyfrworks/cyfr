# The pairing proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a person's
devices pair to their home, that one device confirms what another of theirs
asks for, and that a device loses its channel and its certificate when it
should. A browser holds no device key: its device is the person's passkey,
which its Prism proves with. The devices that pair are a command line (the
real `cyfr` binary) and a test device (`tests/browser/device.mjs`), a client
of the home's device channel that `proof.mjs` drives frame by frame where
the channel itself is what a step proves.

The home is one `cyfr` release on a SQLite cell, `home.test`, reached over
HTTPS through the harness's TLS front (`browser_home`), since a passkey
needs a secure origin. Its device certificates are made short
(`device_cert_seconds`, 20 by default, `PAIRING_PROOF_CERT_SECONDS`) through
the settings operation, as a platform admin sets one, so a certificate
expires within the run.

The person is made by setup with a protected device, as a box's screen or
`cyfr login --setup` makes one (`tests/release-boot/fixture.exs` `person`),
and signed in twice by the release fixture's door: a desktop context, and a
phone context with a mobile viewport. The setup device stands; its seed is
in the cell, read by the fixture's `device_confirm` alone, which confirms
the phone's first passkey. `proof.mjs` drives both contexts in one Chromium,
and the phone's steps once more in a third context, the phone's session at
the handheld's 720×720 touch viewport (`tests/browser/handheld.mjs`).
`run.sh` builds the `cyfr` command line into the output directory's `bin/`
(removed when the run ends), where the command line's steps run it. It asks
`run.sh` for the home's part of a step through its output directory
(`ask-N.json`, answered `answer-N.json`): the setup device's confirmation,
an assertion replayed through the console's adapter under the phone's
session, the certificates' life, and the names of the person's vault
entries.

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
| `passkey` | the phone, signed in to Prism, registers from its Settings page the passkey its authenticator makes: the registration waits on the page's own confirmation, the setup device that made the person confirms it (`device_confirm`), and the page's repeat registers it |
| `pair` | the real `cyfr` binary, which `run.sh` builds and the proof runs on a pseudo-terminal of its own (`script`) beside the browsers, reaching the home through the same proxy and trusting the run's authority, with device certificates living 75 seconds for its steps (`cert_seconds`, restored after): `cyfr login` on a machine without a chip shows a six-word passphrase, writes its key before it shows its code, then shows the key's code and the approve address with a QR code; the desktop types the code under the shell's Devices and begins a pairing for it, as a machine without a camera is approved; it needs a fresh confirmation, which the phone's Prism shows from the home's record — the change, the code among its preview, the client that asked, and that only a passkey or a device may give it — before any proof, and gives with the passkey; the desktop's prompt then shows the pairing link and its QR beside the same code, and no bearer sentence |
| `other_key` | a command line on another machine, with a home directory and a key of its own, given the desktop's link: the pairing does not finish, its record keeps no certificate and it unlocks nothing; the link still pairs the first command line in the next step |
| `command_line` | the link the desktop showed, pasted into the terminal of the command line that showed the code, pairs it with the key it made: the certificate it keeps names that key, whose code is the one it showed; unlocked, in the shell it starts `cyfr whoami` names the person; the passphrase is echoed nowhere but where it is shown |
| `renewal` | 85 seconds on, past the command line's first certificate's life, its shell's `cyfr whoami` still names the person: the certificate renewed over its channel and the session lived on its reports |
| `terminal_confirm` | in that shell `cyfr pair <digest>` asks for another device's addition, a change that needs a fresh confirmation: the terminal draws the home's preview (`pairing.begin`, the digest's code) before it asks the passphrase, asks it once, never echoed, and the passphrase confirms the change on this command line, after which the pairing link is printed and `cyfr pair` exits 0 |
| `open_ticket` | `cyfr open` in that shell names the command line's own page, `http://127.0.0.1:7340/`; a browser context with no cookie opens it and presses Open CYFR, lands on the athanor's canvas with a session cookie of its own, and no ticket is left in its address |
| `exit` | `exit` in the shell: `cyfr login` says it locked and exits 0, the shell's session presented as a bearer opens nothing, and the browser that `cyfr open` signed in is signed out |
| `pin` | on that machine, without a chip, at a home on another machine: `cyfr login --pin` unlocks by the passphrase, asks the new six-digit PIN twice and calls `pin.enroll` through the unlock's session, whose confirmation the terminal draws and the passphrase confirms on this command line; the record then holds a `pin` blob under a `pev_` evaluator, no passphrase blob and no PIN. Three wrong PINs, 0, 1.2 and 2.2 seconds apart, are each said counted; the right PIN within the following 4-second wait opens nothing and says the time of the next try; after the wait it unlocks, and `cyfr pair <digest>` in its shell asks the PIN again and confirms. With the home out of reach (a proxy that answers nothing), as after a reboot, the PIN opens nothing and says CYFR could not be reached |
| `lost_answer` | a second machine holding the command line's key as it stood before the pairing's answer arrived (its home directory copied then) runs `cyfr login`, types the invitation's code alone and the passphrase, and unlocks as the client the home committed for that key: both records name the same client |
| `confirm` | the desktop asks for a credential entry on its vault page, an API key with no label; the phone's Prism shows the desktop's request from the home's record (the change, the entry's name) and the asker before any proof, never the typed value, confirms it with the passkey, the request leaves its layer, and the desktop completes the entry |
| `fresh` | a second entry: the assertion the phone gave for the first, replayed for this record through the console's adapter under the phone's session, is refused, and the desktop's session asking again alone leaves it waiting with nothing made; the phone's fresh assertion, another signature over other client data, confirms it and the desktop completes it |
| `intent` | the device-intent measurement: one discrete intent, `confirmation.pending`, admitted by the gate and dispatched over the test device's channel, 100 in a row, each timed from the frame it sends to the answer naming its id; the test device was paired for a code typed on the desktop and confirmed in the phone's Prism, and opened its confirmations stream |
| `sleep` | the test device stops reading its channel while the desktop asks for a third entry, past the expiry the home's standing named plus four seconds: the home revokes its stream and closes the channel `4408` at the expiry; its expired certificate, presented with a proof of its key on a connection of its own, is refused `4408`; a new connection's first frame is `renew`, the certificate it stands under expires later, its stream is granted anew, and its read of the pending confirmations holds the third entry, which the phone's Prism then cancels |
| `revoke` | the desktop revokes the test device under Devices, confirmed in the phone's Prism with the passkey: the home revokes its stream and then the client and closes the channel `4403`, the desktop's list no longer names it, and its last certificate, presented with a proof of its key, is refused `4403` |
| `viewport` | the phone's steps once more at 720×720, on the phone's session in a context of its own whose authenticator holds the person's passkey: a pairing begun on the desktop for a test device's code, a credential entry and that device's revocation, each read and confirmed with the passkey in that Prism's system layer; each prompt has every control 24×24 CSS px or more, text 12 px or more and nothing overflowing (WCAG 2.2 AA); the Prism page around the prompt is measured and recorded, not held |

## The rows before the browser held no key

Until S4 of the devices plan a browser's `/pair` page made a WebCrypto key
of its own and became a glass. That key is gone; each row it carried is
proven by what replaced it:

| Row then | Proven now by |
|---|---|
| `passkey` (first-method rule on a person with no method) | `passkey`: the setup device confirms the first passkey of a device-first person |
| `pair` (the `/pair` page's code) | `pair`: the command line's code |
| `other_key` (a browser's own key) | `other_key`: another machine's command line |
| `glass` (the link pairs the browser that showed the code) | `command_line`: the link pairs the command line that showed the code, its certificate naming that code |
| `confirm`, `fresh` (on the glass) | `confirm`, `fresh`: in the phone's Prism with its passkey |
| `intent`, `sleep`, `revoke` (the glass's channel) | `intent`, `sleep`, `revoke`: the test device's channel |
| `viewport` (the glass's screens) | `viewport`: the consent prompts in the handheld's Prism |

The test device's channel is read in `proof.mjs` itself: every frame either
way is logged by type, with its grant id and expiry, and each close with
its code, plus the sleep and wake boundaries; no argument, nonce or
signature is kept. Its key is made in that process and never leaves it.

The device-intent measurement is one device on SQLite, one intent at a
time, through the harness's TLS front on a shared host: a baseline, not a
measurement under concurrent load. The record carries its p50, p95 and
p99; no bound is held to them.

# The pairing proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a
person's devices join their account and every CYFR that admits them: a
device is added to the account at the account pages with a passkey, or
from an unlocked command line with `cyfr device approve`; each CYFR admits
it by its hello alone; a device confirms a change its person asked for
in the browser and renews its certificate on its open channel; a key removed from the account ends its device's channel
at every CYFR within the bound; a key removed and added again is
retired and admitted afresh; and a declared restore suspends a CYFR's
own bindings and no key of the account, a device coming back by its
hello. A command line also sets a CYFR up from the
terminal, making the account there and coming in by its hello under the
setup token. Every cell is a `cyfr` release on a SQLite cell of its own,
on a `.test` name behind the harness's TLS front (`browser_home`):

| Cell | Name | Configured |
|---|---|---|
| the directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer`: every account's log, the names beside it and the account pages |
| X, Y | `x.test`, `y.test` | CYFRs the person sets up in the browser; read accounts at `CYFR_DIRECTORY_URL=https://dir.test` and names at `CYFR_REGISTRY_URL=dir.test`; a `CYFR_SETUP_TOKEN` of the run's own each; `CYFR_IDENTITY_FRESHNESS_SECONDS` short (20, `PAIRING_PROOF_FRESHNESS`) |
| Z | `z.test` | configured as X and Y; set up from the terminal |

The CYFRs reach the directory through the identity proof's front
(`tests/identity-proof/front.sh` and `cells.sh`, on the run's own
loopback address). No
DNS, `/etc/hosts`, trust store or other configuration outside the scratch
directory is read or changed. Everything the run starts (the cells'
servers, the front, the Playwright container) and the scratch directory,
with the run's authority key and the setup tokens, is removed when it
ends, whether it succeeds or fails, and so is the command line built into
the output directory's `bin/`.

## The browser, the devices and the command line

The person's passkey is made and used by Chromium's virtual WebAuthn
authenticator over CDP (`tests/browser/account.mjs`); Firefox and WebKit
offer Playwright none, so the proof runs in Chromium alone. The devices
whose channel a step proves are test devices (`tests/browser/device.mjs`),
clients of the CYFRs' device channel `proof.mjs` drives frame by frame,
their keys made in that process: every frame either way is logged by
type, and each close with its code; no argument, signature or token is
kept. The command line is the real `cyfr` binary, built by `run.sh` and
run by `proof.mjs` on a pseudo-terminal of its own (`script`) inside the
Playwright container, on a machine without a chip, so it keeps its key
under a passphrase; it reaches the CYFRs and the directory through the
run's proxy (`HTTPS_PROXY`), trusts the run's authority as the
container's certificate bundle, and reads its directory from
`CYFR_DIRECTORY_URL`.

## Steps

`run.sh` answers the proof's asks for the CYFRs' part (`ask-N.json`,
answered `answer-N.json`); the asks that carried a setup token are deleted
once read. Each step is one row; the proof stops at the first row a later
one rests on.

| Step | What holds |
|---|---|
| `account` | `@pair-a` is made at `dir.test`'s pages and sets up X and Y by signing in with it through each one's setup link |
| `page` | a test device's key is added at `/account/add` with the passkey, the page showing the device's short code; the device's hello, with no capability, admits it at X and at Y, each answering its sign-in request against the log and standing its channel, and each holds it as an active paired client by its kid |
| `command_line` | with x.test its context (`cyfr context add`, `cyfr context set`), `cyfr login` shows a passphrase, asks it twice, then shows the key's code, the address that adds it (a QR code and the link) and the `cyfr device approve` command with the same key, and asks the name; the link opened with the passkey adds it, showing the same code, and the command line goes on by itself: it says hello at X, unlocks and starts a shell whose `cyfr whoami` acts there |
| `approve` | in that shell, `cyfr device approve` with a new test device's key shows that key's short code, asks the passphrase once and adds it to the account; the new device's hello at X stands |
| `terminal_confirm` | an API key the browser asks for at X waits on a fresh confirmation; the first test device reads it over its channel (`confirmation.pending`), asks X's `confirm` request for it (`confirmation.request`), signs the request's digest with its key and answers it (`confirmation.confirm`), and the waiting page makes the key |
| `renewal` | the first test device, on its open channel at X, sends `renew`, signs X's `renew` challenge and takes the certificate X answers: for the same client, living longer than the one it replaced; the channel's `standing` names the replacement's expiry, and the device's next intent is answered under it |
| `remove_key` | the test device's key removed at the devices page: X and Y each close its channel `4403` within their freshness bound (plus six seconds for the device's two-second asks), and neither holds it standing |
| `readd` | added again at the page, the device's hello admits it at X as a new client; then, while it waits, its key is removed and added again, both entries landing between two of X's refreshes: X retires it all the same (`4403`), although the account lists it, and its next hello admits it once more as another client |
| `restore` | x.test stopped, its restore declared as `cyfr restore` declares one (`bin/cyfr eval` of `tests/fixtures/restore_barrier.json`'s `declare_expr`, which answers a `rst_` id) and started again: the device's certificate, presented on a connection of its own, is refused, the browser's next page at x.test lands on the sign-in page, and x.test holds no client of the person standing, while the account's log is as it was; the device's hello admits it again as a new client, and the passkey signs in afresh |
| `setup_terminal` | with z.test its context, `cyfr login --setup --name pair-z` in a directory whose `.env` holds Z's setup token makes the account at the terminal: the passphrase, then the recovery code shown, the directory holding nothing of the account until Enter says it is saved; then the account's log is its genesis and this command line's key alone, its hello brings the token, Z admits the account as its first person (`admission` `setup`) and the command line as its active device, and the shell it starts acts there |

The device's closes are observed by an intent every two seconds, which is
what makes a CYFR read the account's log again past its bound, so each
includes up to one ask past the moment the CYFR retired the device.

A certificate racing a refresh is refused by the issuance fence
(`Sanctum.IdentityFreshness`, `Arca.DirectoryHeads`): a write naming a
head that is no longer the cached one. Two requests at one CYFR cannot be
timed against each other from outside it, so that race is the Elixir
suites' to prove, not this proof's.

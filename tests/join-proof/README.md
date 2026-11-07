# The join proof

`run.sh` proves, on the browser harness (`tests/browser/`), that people
join a CYFR someone else runs with their accounts: its operator sets it
up by signing in with their own account, a newcomer redeems the
operator's invitation in the browser by creating their account at the
account pages, a device redeems another invitation by its hello, and the
CYFR confirms a newcomer's change by their passkey. Every cell is a
`cyfr` release on a SQLite cell of its own, on a `.test` name behind the
harness's TLS front (`browser_home`):

| Cell | Name | Configured |
|---|---|---|
| the directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer`: every account's log, the names beside it and the account pages |
| H | `h.test` | the CYFR people join; reads accounts at `CYFR_DIRECTORY_URL=https://dir.test` and names at `CYFR_REGISTRY_URL=dir.test`; a `CYFR_SETUP_TOKEN` of the run's own, under which its operator sets it up |

H reaches the directory through the identity proof's front
(`tests/identity-proof/front.sh` and `cells.sh`, on `127.77.0.1`). No
DNS, `/etc/hosts`, trust store or other configuration outside the scratch
directory is read or changed. Everything the run starts (the cells'
servers, the front, the Playwright container) and the scratch directory,
with the run's authority key and the setup token, is removed when it
ends, whether it succeeds or fails.

## Chromium alone

Every passkey is made and used by Chromium's virtual WebAuthn
authenticator over CDP (`tests/browser/account.mjs`); Firefox and WebKit
offer Playwright none, so the proof runs in Chromium alone. Each person is
a browser context of their own with their own passkeys. The device that
joins by its hello is a test device (`tests/browser/device.mjs`), a client
of H's device channel `proof.mjs` drives, its key made in that process.

## Steps

`proof.mjs` drives the browsers and the device; `run.sh` answers its asks
for H's part (`ask-N.json`, answered `answer-N.json`), and the ask that
carried the setup token is deleted once read. Each step is one row; the
proof stops at the first row a later one rests on.

| Step | What holds |
|---|---|
| `operator` | `@join-op` is made at `dir.test`'s pages and sets H up through its setup link by signing in with the account (`admission` `setup`) |
| `invited` | the operator makes an invitation on H's Settings page; a newcomer with no account opens the link, which names no code on the page, and taps "Create your account": the new page, holding H's sign-in request, makes `@join-b`, shows and saves its code, makes its passkey and then signs H's request with it ("Continue to https://h.test"); H admits the account under the invitation (`admission` `invitation`) and signs them in |
| `spent` | the same link a second time says it can no longer be used |
| `confirm` | the newcomer asks for an API key at H, which waits on a fresh confirmation: "Confirm with a passkey" opens the sign page in a new tab, which says "Confirm a change at https://h.test"; the passkey signs it, the tab returns to H, and the waiting page makes the key |
| `device` | `@join-d` is made at the pages, and a test device is added to it at `/account/add` with that account's passkey, the page showing the device's short code; the device's hello at H brings another invitation's code: H answers its sign-in request, admits the account under the invitation, issues the device its certificate and stands its channel on that connection, holds the device as an active paired client by its kid, and the link is spent |

The refusals of a sign-in or confirmation answer (another browser's
binding, a replay, another audience, no user verification, another
person's confirmation, an expired request) are the Elixir suites' to
prove, not this proof's. An externally operated directory is not
provided: the directory here is a disposable writer the run starts.

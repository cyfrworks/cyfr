# The identity proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a person
makes their account at the account pages of a directory, signs in with
it at a CYFR that relies on that directory, keeps a second recovery code,
and changes the account with their codes and passkeys, and that the CYFR
follows each change in the account's log within its freshness bound: a
removed key loses what it signed in, a replaced account loses every
session, and an account the directory marks gone signs in nowhere. Every
cell is a `cyfr` release on a SQLite cell of its own, on a `.test` name
behind the harness's TLS front (`browser_home`), since a passkey needs a
secure origin:

| Cell | Name | Configured |
|---|---|---|
| the directory | `dir.test` | `CYFR_DIRECTORY_SERVE=writer`: the account's log, the names beside it and the account pages, whose passkeys are bound to `dir.test` |
| A | `a.test` | a CYFR that reads accounts at `CYFR_DIRECTORY_URL=https://dir.test` and names at `CYFR_REGISTRY_URL=dir.test`; a `CYFR_SETUP_TOKEN` of the run's own, under which the person sets it up; `CYFR_IDENTITY_FRESHNESS_SECONDS` short (20, `IDENTITY_PROOF_FRESHNESS`) |

The account pages live only at a directory that serves them over HTTPS,
so the directory is a CYFR cell rather than the registry stand-in
(`tests/registry-stand-in/`), which serves no pages and is reached over
plain HTTP, where no browser makes a passkey.

## How A reaches the directory

The browsers reach every cell through the harness's proxy. A's own
directory client speaks HTTPS to `https://dir.test` through Sanctum's
pinned egress, and the harness resolves no name. So this proof adds, in
pieces another proof sources (`tests/join-proof/` and
`tests/pairing-proof/` among them):

- `front.sh` and `front.mjs`: each directory a proof runs is declared
  by its name (`identity_directory dir.test`), and its front stands on a
  loopback address of the run's own, made from the run's pid, so proofs
  run side by side. Each front is one container of the pinned Playwright
  image per run and directory, `cyfr-identity-front-<pid>-<name>`, on the
  host network as root so it can listen on port 443 of its own loopback
  address, presenting the certificate the run's authority issued for its
  name and forwarding to its directory cell as Caddy forwards. Its control
  listener (port 9443 of that address) takes the directory down on purpose
  (`identity_front_fault NAME down`, and `none` again) and reports every
  request that reached it (`identity_front_seen NAME`). A front answers
  `/health` with a token the run passed it, and its readiness is accepted
  only from that token, so a stale or foreign listener on the front's
  address is refused.
- `cells.sh`: each CYFR's deployment file gains `ERL_INETRC` (an inetrc
  of the run's own naming every declared directory at its front's
  address), every front's address in `CYFR_PRIVATE_EGRESS_TARGETS`, and
  `CYFR_DIRECTORY_URL` (`identity_reaches_directory CELL NAME`); once its
  server answers, the node takes the run's authority as its trusted store
  (`:public_key.cacerts_load/1` over `bin/cyfr rpc`), as an operator adds
  a certificate authority to a node's store. No test seam is set in any
  release. `identity_fixture` evaluates `fixture.exs` inside a running
  cell.

No DNS, `/etc/hosts`, trust store or other configuration outside the
scratch directory is read or changed. Everything the run starts (the
cells' servers, the front, the Playwright container) and the scratch
directory, with the run's authority key and the setup token, is removed
when it ends, whether it succeeds or fails.

## Chromium alone

The person's passkeys are made and used by Chromium's virtual WebAuthn
authenticator over CDP (`tests/browser/account.mjs`); Firefox and WebKit
offer Playwright none, so the proof runs in Chromium alone. The person
uses three browsers over the run, each a context of its own with its own
passkeys: the laptop, the phone, and a new device after the account is
replaced.

## Steps

`proof.mjs` drives the browsers; `run.sh` answers its asks for the
servers' part (`ask-N.json`, answered `answer-N.json`), and the ask that
carried the setup token is deleted once read. Each step is one row; the
proof stops at the first row a later one rests on.

| Step | What holds |
|---|---|
| `account` | `@identity-a` is made at `dir.test`'s `/account/new`: the recovery code is shown and saved before the passkey is made, the log holds the genesis and the passkey's `add_key`, `dir.test` answers the name with the account's identifier and directory, the passkey's user handle is the identifier's digest, and neither the code nor its secret is in the page's storage, its address or any request the proxy saw |
| `sign_in` | the laptop opens A's setup link and signs in with the account: the sign page says "Sign in to https://a.test", A admits the account under its setup token (`admission` `setup`), binds the session to the passkey's kid and caches the account's head |
| `second_code` | the recovery page, opened with the first code, draws a second code for the same account, shows it before it is added (`add_recovery`), and the second code opens the page |
| `remove_key` | the phone adds a passkey with the second code and signs in at A; the laptop removes that passkey at the devices page (`remove_key`); the phone's next page at A lands on the sign-in page within A's freshness bound (plus six seconds for the page loads that ask), its paired client is revoked, and the laptop's session stands |
| `recover` | "Replace everything" with the second code leaves the account one new code and no key (`recover`); the laptop's next page at A lands on the sign-in page within the bound; the first code no longer opens the recovery page and the laptop's passkey signs in nowhere; a passkey the new code adds on a new device signs in at A as the same person |
| `directory_down` | with `dir.test` down, A answers the head it verified within its bound and pauses the person past it (`identity_stale`) |
| `gone` | `dir.test`'s tombstone (`Sanctum.Directory.tombstone/1`, the path the operation `directory.tombstone` takes) answers `410 gone` for the log; the new device's next page at A lands on the sign-in page within the bound, A's cached head is marked gone and answers `identity_gone`, and the passkey's next sign-in at A is refused |

Each retirement is observed by loading a page of A every two seconds from
the moment the directory took the change, so it includes up to one page
load past the moment A retired the session.

What this proof does not cover is the join proof's (`tests/join-proof/`),
admission by invitation, and the pairing proof's (`tests/pairing-proof/`),
devices. An externally operated directory is not provided: the directory
here is a disposable writer the run starts, which proves no hosted service.

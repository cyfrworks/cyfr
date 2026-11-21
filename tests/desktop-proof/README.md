# The CYFR app's proofs

Two kinds, by what they need.

**`native/smoke.sh`**, home-free: the installed production app on Linux,
macOS and Windows, with no CYFR and no signing credentials (Codex CI's
`desktop-native` job; its header lists the checks).

**`*/run.sh`, against a real CYFR**: every tracked `tests/desktop-proof/*/run.sh`,
in sorted order, run by `home.sh` (the Test workflow's `desktop-home` job, on
Linux amd64 and arm64):

    tests/desktop-proof/home.sh DEB IMAGE

For each script `home.sh` starts afresh, in the pairing proof's topology
(`tests/pairing-proof/README.md`):

| Part | What it is |
|---|---|
| `dir.test` | the account directory (`CYFR_DIRECTORY_SERVE=writer`) |
| `x.test` | the CYFR the app connects to, reading accounts at `https://dir.test` and names there, with a setup token of the run's own |
| the fronts | the identity proof's TLS front for each name (`tests/identity-proof/front.sh`), on the run's own loopback addresses, forwarding WebSocket upgrades too; each records what reached it, by user agent, and can go down on demand |
| the client | an `ubuntu:24.04` container on the host's network: the DEB installed as a person installs it, its sandbox under the container's own namespaces, a display (Xvfb) and a session bus, the user `proof`, and the run's authority trusted by the system (which `cyfr` reads) and by that user's NSS store (which the app's engine reads); no Docker program or socket, and nothing else configured |

Both CYFRs are the release inside `IMAGE`, the app image of the DEB's
architecture, run as this user on the host's network with each cell's own
settings (`tests/release-boot/release.sh` cells, whose `bin/cyfr` here runs
the image's). The app is given the CYFR's address and the trust alone: the
script and its proof get `FIXTURE_DIR/inputs.json` (the CYFR's and the
directory's addresses, the setup token, each front's control address) and
`authority.pem`.

A script whose folder holds a `proof.js` runs it as the app's entry: `pack.mjs`
bundles it as the production entry is bundled, carrying the proof-only
marker the package guard refuses (`apps/codex/desktop/test/check-package.test.mjs`
proves each such bundle is refused), and the client installs it in place of
the installed `app.asar`, in that container alone. The proof runs the
production `startApp` with the installed `cyfr` and drives the app from
inside its own main process through each window's `webContents`; no port
opens. What the proof shares with the shipped app: the Electron, the
`cyfr`, the package and its sandbox profile as installed, and the main
process's code, `startApp` and everything it runs. What it does not: the
entry file, which here starts `startApp` and then drives it, and one window
of the proof's own beside the app's, the person's second client.

Everything a script's run starts, the homes, fronts, client and scratch
directory with the run's authority key and setup token, is removed when it
ends; its record (`out/`) is copied to `PROOF_OUT`. The run needs
127.0.0.1:7340 free on this machine.

The fronts' control (`tests/identity-proof/front.mjs`) breaks or bends a
CYFR on purpose: `down` (unreachable), `hold` (each request waits
unanswered, and one its client gives up is recorded so) and `directory`
(the sign-in page names another account directory).

## `connect/`: the six-word road

The person's second client is a browser window of the proof's own, with the
account's passkey on Chromium's virtual authenticator (CDP through its
`webContents.debugger`), as their phone would hold it. The proof's entry
gives the app's engine a fake camera and microphone, so a page the app let
have them would get them. Each row is a claim about the running app and
fails when the behaviour it names is broken; the proof stops at the first
that fails. The proof has 28 rows over three launches of the app (`run.sh`): `connect`, then
`remembered` and `changed` on what that left on this computer.

| Row | What holds | What the row observes |
|---|---|---|
| `docker_absent` | the client has no Docker program or socket | the client's own environment |
| `account`, `setup` | the person's account made at `dir.test` with the passkey, and `x.test` set up with it, on the second client | the account pages and the CYFR answering |
| `media_control` | this run's camera and microphone are there to grant | the second client, which grants them, gets both |
| `chooser` | the app opens at Connect to a CYFR and, where it cannot hear the computer's lock (the container has no system bus), says so in one sentence | the chooser's page |
| `custom_directory` | an account service other than cyfr.run is shown whole and asked about | the chooser's question |
| `lock_during_connect` | a lock while a Connect runs ends it; the chooser comes back and `cyfr` runs on | `cyfr`'s request for the CYFR's sign-in page held at the front (fault `hold`), then, after the lock, given up by `cyfr`; the chooser again; no end of `cyfr` |
| `decline` | Cancel says nothing was sent, and nothing of the app reaches the account service until it is approved; the next Connect asks again | the front of `dir.test`, from before the first question to the approval |
| `device_pages` | once approved, the device's pages | the device's pages |
| `enrolment_page` | with a passphrase given, the enrolment page shows the key's code beside the account service's address | the enrolment page alone; that the key is made under the passphrase is the Go holder's tests' to show, not this row's |
| `admission_refused` | "I approved it" before any approval is refused, and says so | the device's page |
| `approved` | the second client shows the same code and adds the key with the passkey | the account pages |
| `prism` | the device is admitted and Prism opens in the content window, signed in | the content window and its session cookie |
| `passkeys` | both passkey calls, in Prism's page and in a frame of it, are refused by the app's permissions policy (Prism names none for its page) | each call's refusal, which names the denied feature, and the reported feature policy |
| `media` | the camera and the microphone are refused to Prism's page and to a frame it allows them to | each request's `NotAllowedError` |
| `navigation` | main refuses the top frame sent elsewhere, a window elsewhere, a frame sent to the CYFR's company sign-in and a frame moving the top frame (asked from inside the frame, so the engine's initiator is the frame); Prism's page and the frame allow each | main's decision on each navigation's event and on the window request, read from its window handler; nothing at the front for the company sign-in |
| `prism_frame_rules` | Prism's own frame rules hold in the app: a frame Prism serves (a canvas) is given no window and cannot move the top frame. This is Prism's sandbox refusing, not the app | the engine's answers in the frame |
| `confirm` | an API key asked for in Prism waits on the device's own window: a wrong passphrase is refused and asked again, the right one confirms it | the refusal and the same confirmation asked again, no key in Prism; then the key shown in Prism |
| `lock`, `system_lock`, `renderer_loss` | Prism's Lock, the computer's lock (main's lock-screen event, as the system sends it) and Prism's page stopping each close Prism and sign its session out, confirmed | the session's cookie opening a page before; main's sign-out answered at the front with the CYFR's acknowledgement; the chooser opened with no unconfirmed notice; the cookie refused after. On this road `cyfr`'s lock also retires the session through the device's channel, so the refused cookie alone does not tell which retired it; the passkey road shows the sign-out alone |
| `system_lock_at_once` | the computer's lock closes Prism's window at once | the window, destroyed before anything is awaited |
| `reconnect` | the lock left the device locked; its passphrase opens Prism again under a new session | the locked device's page first; a new session cookie |
| `offline_lock` | with the CYFR unreachable, the lock still closes Prism, and the chooser says the sign-out is unconfirmed | the front taking `down`; the chooser's notice |
| `process_loss` | `cyfr` killed while Prism holds a session: the app closes its content for good, signs the session out, confirmed, and tells the person | the app's message; the acknowledged sign-out; the cookie before and after |
| `remembered` | launched again, the CYFR's approved account service is not asked about again | the device's pages, with no question |
| `directory_changed` | a CYFR that names another account service than the one approved is asked about afresh | the question, with the front standing in for a CYFR reconfigured (fault `directory`) |
| `approval_ended` | that earlier approval has ended: named again, the first account service is asked about again, and nothing of the app reaches it | the question; the front of `dir.test` |

What a proof records holds no credential: addresses without their
fragments, headings and notices, never a page's text.

Not here: the passkey road (`passkey/`, next), the computer's real lock and
sleep and Windows Hello (a person at the machine), and macOS and Windows
(`desktop-native`).

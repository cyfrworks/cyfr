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

## `connect/`: the six-word road

The person's second client is a browser window of the proof's own, with the
account's passkey on Chromium's virtual authenticator (CDP through its
`webContents.debugger`), as their phone would hold it. Each row is a claim
about the running app; the proof stops at the first that fails.

| Row | What holds |
|---|---|
| `docker_absent` | the client has no Docker program or socket |
| `account`, `setup` | the person's account made at `dir.test` with the passkey, and `x.test` set up with it, on the second client |
| `chooser` | the app opens at Connect to a CYFR and, where it cannot hear the computer's lock (the container has no system bus), says so in one sentence |
| `custom_directory`, `decline` | an account service other than cyfr.run is shown whole and asked about once, and nothing of the app reaches it before; Cancel says nothing was sent and nothing was |
| `lock_during_connect` | a lock while the approved Connect runs ends it; the chooser comes back and `cyfr` runs on |
| `device_pages`, `device_key` | once approved, the device's pages; the key made under the passphrase, its code shown beside the account service's address |
| `admission_refused` | "I approved it" before any approval is refused, and says so |
| `approved` | the second client shows the same code and adds the key with the passkey |
| `prism` | the device is admitted and Prism opens in the content window, signed in |
| `headers`, `media` | Prism's page and a frame of it are denied both passkey calls, the camera and the microphone |
| `navigation` | the top frame cannot leave the CYFR or open a window elsewhere; a frame loads neither another origin nor the CYFR's company sign-in; a frame cannot move the top frame (asked from inside the frame, so the engine's initiator is the frame) |
| `prism_frame` | a frame Prism serves (a canvas) asking for a window or for the top frame gets neither |
| `confirm` | an API key asked for in Prism is confirmed on this device, in the device's own window, with the passphrase again |
| `lock`, `reconnect` | Prism's Lock closes Prism; the session's sign-out is acknowledged and its cookie opens nothing more; the passphrase opens Prism again under a new session |
| `system_lock_at_once`, `system_lock` | the computer's lock (main's lock-screen event, as the system sends it) closes Prism's window at once, and the session is signed out, confirmed |
| `offline_lock` | with the CYFR unreachable, the lock still closes Prism, and the chooser says the sign-out is unconfirmed |
| `renderer_loss` | Prism's page stopping locks the app and signs its session out |
| `process_loss` | `cyfr` killed: the app closes its content for good and tells the person |

Not here: the passkey road (`passkey/`, next), the computer's real lock and
sleep and Windows Hello (a person at the machine), and macOS and Windows
(`desktop-native`).

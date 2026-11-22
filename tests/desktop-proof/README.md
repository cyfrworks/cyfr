# The CYFR app's proofs

Three kinds, by what they need.

**`native/smoke.sh`**, home-free: the installed production app on Linux,
macOS and Windows, with no CYFR and no signing credentials (Codex CI's
`desktop-native` job; its header lists the checks).

**`screen/idle.sh`, the device screen's idle lock**, with no CYFR (Codex
CI's `screen-idle` job, amd64): this tree's watches under Ubuntu 26.04's
labwc beside a real Chrome with the screen's flags, with nothing playing,
with a page playing a video a tap started and with a sandboxed frame
playing one; and the suspend watch over the real swayidle and a stand-in logind.
Each video row holds that the watch locks while the control, swayidle's
ordinary timeout, is held off, and that this same control fires once the
playback ends: a page that held no idle inhibitor, or a control that could
not fire, fails rather than show nothing. The frame
stands for an app's, with Prism's sandbox for no grant; no CYFR serves
it. Its header names the rest.

**`*/run.sh`, against a real CYFR**: every tracked `tests/desktop-proof/*/run.sh`,
in sorted order, run by `home.sh` (the Test workflow's `desktop-home` job, on
Linux amd64 and arm64):

    tests/desktop-proof/home.sh DEB IMAGE

For each script `home.sh` starts afresh, in the pairing proof's topology
(`tests/pairing-proof/README.md`), the CYFR its folder's `home` file names
(`separate` without one):

| Shape | The CYFR |
|---|---|
| `separate` | `x.test`, reading accounts at the account directory `dir.test` (`CYFR_DIRECTORY_SERVE=writer`) and names there |
| `self` | `x.test` serving its own account pages: the CYFR and its account service share one origin |
| `company` | `x.test` serving its own account pages and requiring a company sign-in (`CYFR_COMPANY_LOGIN=join`) at the OIDC issuer `idp.test`, a front with nothing behind it, which only records what reaches it. Only the client is told that front's address, so every request there is the client's and counts |

Each has a setup token of the run's own.

| Part | What it is |
|---|---|
| the fronts | the identity proof's TLS front for each name (`tests/identity-proof/front.sh`), on the run's own loopback addresses, forwarding WebSocket upgrades too; each records what reached it, by user agent, and can go down on demand |
| the client | an `ubuntu:24.04` container on the host's network: the DEB installed as a person installs it, its sandbox under the container's own namespaces, a display (Xvfb) and a session bus, the user `proof`, and the run's authority trusted by the system (which `cyfr` reads) and by that user's NSS store (which the app's engine reads); no Docker program or socket, and nothing else configured |

Both CYFRs are the release inside `IMAGE`, the app image of the DEB's
architecture, run as this user on the host's network with each cell's own
settings (`tests/release-boot/release.sh` cells, whose `bin/cyfr` here runs
the image's). The app is given the CYFR's address and the trust alone: the
script and its proof get `FIXTURE_DIR/inputs.json` (the CYFR's and its
account directory's addresses, the setup token, each front's
control address) and `authority.pem`.

A script whose folder holds a `proof.js` runs it as the app's entry, on what
every such proof shares (`lib.js`: the run, the second client, the fronts,
the app's windows, what a stopped proof records; `launch.sh`: one launch of
the app a phase; `account.js`: the account road's steps): `pack.mjs`
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
unanswered, and one its client gives up is recorded so), `directory` (the
sign-in page names another account directory) and `redirect` (a path is
answered with a redirect elsewhere).

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
| `lock`, `system_lock`, `renderer_killed` | Prism's Lock, the computer's lock (main's lock-screen event, as the system sends it) and Prism's page's process ended by the kill signal (as the kernel ends one when memory runs out) each close Prism and sign its session out, confirmed | the session's cookie opening a page before; main's sign-out answered at the front with the CYFR's acknowledgement; the chooser back and, with nothing to tell, gone on to the device's pages by itself; the cookie refused after. On this road `cyfr`'s lock also retires the session through the device's channel, so the refused cookie alone does not tell which retired it; the passkey road shows the sign-out alone |
| `system_lock_at_once` | the computer's lock closes Prism's window at once | the window, destroyed before anything is awaited |
| `reconnect` | the lock left the device locked; its passphrase opens Prism again under a new session | the locked device's page first; a new session cookie |
| `offline_lock` | with the CYFR unreachable, the lock still closes Prism, and the chooser stays with the words that the sign-out is unconfirmed until the person goes on | the front taking `down`; the notice's words and the chooser's way on, both in sight, with no move to the device's pages before that way on is pressed |
| `notice_kept` | a second lock and a reload over the chooser that is keeping a notice leave the notice there | the words, staying, after each; `renderer_killed` then shows that the way on taken from it cleared it |
| `process_loss` | `cyfr` killed while Prism holds a session: the app closes its content for good, signs the session out, confirmed, and tells the person | the app's message; the acknowledged sign-out; the cookie before and after |
| `remembered` | launched again, the CYFR's approved account service is not asked about again | the device's pages, with no question |
| `directory_changed` | a CYFR that names another account service than the one approved is asked about afresh | the question, with the front standing in for a CYFR reconfigured (fault `directory`) |
| `approval_ended` | that earlier approval has ended: named again, the first account service is asked about again, and nothing of the app reaches it | the question; the front of `dir.test` |

After `renderer_killed` the proof crashes Prism's page the engine's own
way (`forcefullyCrashRenderer`) and records, without asserting, whether
and how soon the engine reported the page gone. When it has not within
15 s, the record keeps that process's state and the machine's core pattern
(also kept whenever a proof stops), and the proof ends the process with the
kill signal and goes on. This shows a limit of the app: when a page's
process starts to crash and does not exit, the engine reports nothing, and
the window stays open and unanswering until the person closes it or the
computer locks. On GitHub's Linux runners the engine reported nothing for
over a minute; on the machine this proof was written on it reported the
page gone within a tenth of a second.

What a proof records holds no credential: headings and notices, never a
page's text, and addresses cut at their fragment or query and without the
credential some carry in their path (a sign-in's ticket, a canvas's or a
served file's asset credential). One scrub does it for everything written,
the app's own output too, before it is written (`scrub.mjs`).

## The passkey road: `passkey/`, `passkey-self/`, `passkey-company/`

The app runs with the passkey road on, as on macOS and Windows; on Linux it
offers the six-word road alone. The chooser offers Sign in with your
passkey only on macOS and Windows, so the proof goes from the device's pages
to the CYFR's sign-in page itself, as that button does. The app's account
window gets a virtual authenticator (CDP through its own
`webContents.debugger`) standing in for this computer's platform
authenticator, armed afresh for each ceremony with the passkeys this
computer holds; the person's answer in the app's "Sign in as" dialog is
stood in for, with what it offered recorded.

**`passkey/`** (shape `separate`). This computer's device is enrolled on the
six-word road first: a passkey a browser makes is approved only on a
device's own screen, so it is the trusted device for the passkey the
account window makes.

| Row | What holds | What the row observes |
|---|---|---|
| `device` | this computer's device is enrolled and opens Prism | Prism |
| `passkeys_policy` | with a usable authenticator in the content window, both passkey calls in the CYFR's page and a frame are refused by the app's policy | each call's refusal naming the denied feature |
| `no_passkey` | Sign in opens the app's account window at the account service; with no passkey it says so and offers to make one | the account window's origin and page |
| `offer` | a passkey made in the account window returns to the CYFR's sign-in page, which shows its code | the code in the content window; the passkey the authenticator added |
| `matched_code` | the device's Your devices and its own window show the same code, and with the passphrase the passkey is added to the account | the code in both; the account's log at the directory, without that key before and with it after |
| `passkey_sign_in` | the new passkey alone signs in: the account window's answer returns and Prism opens | Prism, a session, the account offered |
| `devices` | Your devices lists the passkey and how it signs in | the listed passkey |
| `confirm` | a key asked for in Prism is confirmed with the passkey in the account window | the confirmation's page; the key shown |
| `sign_out_alone` | the lock signs the passkey's session out, acknowledged; with no device channel, the sign-out alone retires it | the cookie opening a page before; the acknowledgement at the front; the cookie refused after |
| `resume` | after the lock the CYFR sends the content to its sign-in, and a fresh assertion opens Prism | the sign-in page; a new session; the old cookie refused |
| `choose_cancel` | with two accounts' passkeys the app offers both; Cancel signs no one in; choosing @desk-a signs in as @desk-a | what the dialog offered; the page's refusal; Prism |
| `account_offline` | with the account service unreachable the account window opens the copy its worker stored, and that copy still carries main's refusal of a frame | the service's front taking `down` and answering none of it; the worker controlling the page it served; the engine's report of main's policy refusing the frame |
| `account_window` | main refuses a frame's load in the account window, and the CYFR's own page by navigation and by redirect, and either of those ends the ceremony | the engine's report of the policy main adds refusing that frame's address, apart from the account service's own policy, and nothing of it at the service's front; main's decisions; the window gone; nothing at the CYFR's front |
| `recovery` | the recovery code adds a passkey in the account window's recovery page, which returns to the sign-in and signs in | the passkey added; Prism |
| `wrong_window` | an answer made for another browser's sign-in signs no one in when given to the content window. This is the CYFR's binding of an answer to the browser that asked, holding in the app | the CYFR's refusal; the page's cookie opens nothing |

**`passkey-self/`** (shape `self`): `same_origin_hop` (the sign-in opens
the CYFR's own account page in the account window), `same_origin_sign_in`,
`passkeys_policy` (Prism's page, at the account pages' own origin, refused
both calls) and `home_paths` (the account window refuses the CYFR's own
page at that same origin, and the ceremony ends).

**`passkey-company/`** (shape `company`).

| Row | What holds | What the row observes |
|---|---|---|
| `account_road` | the passkey signs in, the CYFR's company page closes it in the app, and the chooser stays to send the person to a browser | the sentence's words and the chooser's way on, both in sight, with no move before it is pressed; no request starting a company sign-in and none at the issuer |
| `device_road` | the device's page says the same once the CYFR refuses the device | the sentence on the device's page; the same two counts |

The chooser is `cyfr`'s own as Linux has it, with nothing stood in: with a
notice to show it stays until Use this computer's key is pressed, and with
none it goes on by itself. The company run also records, without asserting,
what the sign-out was answered: whether main's forgery token was missing or
stale.
On a CYFR that requires a company sign-in the app's lock is unconfirmed,
and the session left can reach only the company page.

A limit of the app: when main's load of a sign-in's answer is rejected,
as when the CYFR's page still had a load of its own pending, nobody is
signed in and nothing says so, and pressing Sign in again works. And a
notice not yet read is lost when the person quits.

Not here: the computer's real lock and sleep, Touch ID and Windows Hello (a
person at the machine), and macOS and Windows (`desktop-native`).

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
account directory's addresses, the setup token, the port the CYFR asks
its worker service at, where nothing listens unless a proof answers, and
each front's control address) and `authority.pem`.

A script whose folder holds a `proof.js` runs it as the app's entry, on what
every such proof shares (`lib.js`: the run, the second client, the fronts,
the app's windows, what a stopped proof records; `bound.mjs`: a timed
row's clock, which starts with its cause; `launch.sh`: one launch of
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
that fails. The proof has 29 rows over three launches of the app (`run.sh`): `connect`, then
`remembered` and `changed` on what that left on this computer.

| Row | What holds | What the row observes |
|---|---|---|
| `docker_absent` | the client has no Docker program or socket | the client's own environment |
| `account`, `setup` | the person's account made at `dir.test` with the passkey, and `x.test` set up with it, on the second client | the account pages and the CYFR answering |
| `media_control` | this run's camera and microphone are there to grant | the second client, which grants them, gets both |
| `chooser` | the app opens at Connect to a CYFR, with nothing to tell and, on this road, no passkey and no other CYFR to go to | the chooser's page |
| `custom_directory` | an account service other than cyfr.run is shown whole and asked about | the chooser's question |
| `decline` | Cancel says nothing was sent, and nothing of the app reaches the account service until it is approved; the next Connect asks again | the front of `dir.test`, from before the first question to the approval |
| `device_pages` | once approved, the device's pages | the device's pages |
| `enrolment_page` | with a passphrase given, the enrolment page shows the key's code beside the account service's address | the enrolment page alone; that the key is made under the passphrase is the Go holder's tests' to show, not this row's |
| `admission_refused` | "I approved it" before any approval is refused, and says so | the device's page |
| `approved` | the second client shows the same code and adds the key with the passkey | the account pages |
| `prism` | the device is admitted and Prism opens in the content window, signed in | the content window and its session cookie |
| `passkeys` | both passkey calls, in Prism's page and in a frame of it, are refused by the app's permissions policy (Prism's own policy names neither call) | each call's refusal, which names the denied feature, and the reported feature policy |
| `media` | the camera and the microphone are refused to Prism's page and to a frame it allows them to | each request's `NotAllowedError` |
| `navigation` | main refuses the top frame sent elsewhere, a window elsewhere, a frame sent to the CYFR's company sign-in and a frame moving the top frame (asked from inside the frame, so the engine's initiator is the frame); Prism's page and the frame allow each | main's decision on each navigation's event and on the window request, read from its window handler; nothing at the front for the company sign-in |
| `prism_frame_rules` | Prism's own frame rules hold in the app: a frame Prism serves (a canvas) is given no window and cannot move the top frame. This is Prism's sandbox refusing, not the app | the engine's answers in the frame |
| `confirm` | an API key asked for in Prism waits on the device's own window: a wrong passphrase is refused and asked again, the right one confirms it | the refusal and the same confirmation asked again, no key in Prism; then the key shown in Prism |
| `lock` | Prism's Lock closes Prism at once, ends its session and forgets it | the content closed before anything is awaited; the session's cookie opening a page before and refused after; none left in the content's session; no sign-out posted by the app (`cyfr`'s lock ends the session through the device's channel); the chooser back and, with nothing to tell, gone on to the device's pages by itself, no button pressed |
| `reconnect` | the lock left the device locked; its passphrase opens Prism again under a new session | the locked device's page first; a new session cookie |
| `computer_lock` | the computer's lock and sleep are not the app's | main's `lock-screen` and `suspend` events, as the system sends them, and for two seconds after: the same window, page and cookie, still opening a page; no chooser; no sign-out |
| `renderer_killed` | Prism's page's process ended by the kill signal (as the kernel ends one when memory runs out) is shown again, signed in as before | the engine's report; the same window loaded again and connected; the same cookie; no lock and no sign-out |
| `unanswered` | a page of the CYFR that did not load gives way to the chooser in the same window, naming the CYFR, the device's session as it was | main saying the failure and the front, taking `down`, the request of the page asked for; the sentence and the way on in sight, with no Try again on this road; the same window, and the same cookie still opening a page; no lock and no sign-out |
| `opened_again` | that chooser's way on shows the device's unlocked page, and Open CYFR there opens Prism with no passphrase asked | exactly that one page on the way, unlocked; Prism connected |
| `offline_lock` | with the CYFR unreachable, Prism's Lock still closes Prism at once and goes on to the locked device's page | the front taking `down`; the content closed before anything is awaited; nothing told and the passphrase asked; no sign-out; the cookie refused, looked for from the press on and seen within one minute of it |
| `process_loss` | `cyfr` killed while Prism holds a session: the app closes its content for good and tells the person, and the session ends with the device's channel | the app's message, saying nothing of a sign-out; none posted; the cookie opening a page before and refused, looked for from the kill on and seen within one minute of it (`bound.mjs`) |
| `remembered` | launched again, the CYFR's approved account service is not asked about again | the device's pages, with no question |
| `asks_again` | launched again, this road keeps no sign-in | the device's page asking for the passphrase, and no cookie |
| `directory_changed` | a CYFR that names another account service than the one approved is asked about afresh | the question, with the front standing in for a CYFR reconfigured (fault `directory`) |
| `approval_ended` | that earlier approval has ended: named again, the first account service is asked about again, and nothing of the app reaches it | the question; the front of `dir.test` |

After `renderer_killed` the proof crashes Prism's page the engine's own
way (`forcefullyCrashRenderer`) and records, without asserting, whether
and how soon the engine reported the page gone. When it has not within
15 s, the record keeps that process's state and the machine's core pattern
(also kept whenever a proof stops), and the proof ends the process with the
kill signal and goes on. This shows a limit of the app: when a page's
process starts to crash and does not exit, the engine reports nothing, and
the window stays open and unanswering until the person closes it. A
process reported gone has its page shown again. On GitHub's Linux runners the engine reported nothing for
over a minute; on the machine this proof was written on it reported the
page gone within a tenth of a second.

What a proof records holds no credential: headings and notices, never a
page's text, and addresses cut at their fragment or query and without the
credential some carry in their path (a sign-in's ticket, a canvas's or a
served file's asset credential). One scrub does it for everything written,
the app's own output too, before it is written (`scrub.mjs`).

## `media/`: camera and microphone

The shipped app refuses both, and Prism draws no control that captures.
The composer's hook holds the capture all the same (`cyfr:capture`,
`apps/cyfr/assets/js/hooks/aqua_chat.js`), and this proof drives it with
the engine's fake devices and no automatic grant. The grant is the proof
entry's alone: it wraps each session's two permission handlers as the
app sets them, and allows `media` to the one content window it pins, for
that window's top frame when the asking document's security origin is the
CYFR's. An ask that names no security origin is refused, whatever address
it names. A send needs a worker
service that answers its status, so the entry answers that alone, from
`tests/fixtures/worker_api.json`. No brain's turn runs in this proof:
that a brain is told it cannot read the clip is the Elixir test's to
show (`apps/cyfr/test/aqua/crew_test.exs`).

| Row | What holds | What the row observes |
|---|---|---|
| `grant_chooser` | the chooser, in the content window while it is pinned, is refused | each request's `NotAllowedError` |
| `media_shipped` | with nothing granted, Prism's page and the composer's own capture are refused both devices, and no file is made | each request's `NotAllowedError`; the empty draft |
| `no_control` | Prism draws no control that captures | the composer's controls, exactly; no control on the page naming a camera, a microphone or a recording |
| `media_granted` | granted by the entry, the CYFR's top page in the content window gets both | each request's answer |
| `grant_security_origin` | an ask with no security origin is refused | both installed handlers, asked directly: refused without one though the address is the CYFR's, allowed with the CYFR's |
| `grant_frame` | a frame of the page's own origin, allowed both by the page, is refused | each request's `NotAllowedError` |
| `grant_window` | the CYFR's page in another window of the same session is refused | the same, at the CYFR's origin |
| `grant_kind` | the grant is for media alone | another permission still denied, to the page and by both handlers |
| `screen_refused` | screen capture is refused | the refusal naming Prism's `display-capture` policy; `getUserMedia`'s road to a screen refused |
| `capture_sends_nothing` | a still and a clip wait in the draft | two uploads waiting, nothing in the thread |
| `capture_files` | sent, both are stored, fetched back and decoded | a patterned PNG; sound of over nine and at most ten seconds |
| `capture_released` | a finished capture keeps no device | every track given, ended |
| `cancel` | a cancel stops a recording at once and attaches nothing | the track ended; the draft empty |
| `composer_closed` | the composer closing stops a recording | the track ended |
| `lock` | the device's Lock ends a recording | the window destroyed and its page's process gone, sooner than the clip would end |

Limits: the clip's timer is the page's, so a page that stalls can run a
clip over ten seconds. A recording is not tied to the computer's lock:
it ends by itself within its bound. A thread switched inside the open
panel keeps the composer, so a clip under way lands in the draft shown.
An unanswered browser prompt can outlast the composer: its end doesn't
withdraw the prompt, and whatever the prompt then gives is stopped at
once and makes no file.

## The passkey road: `passkey/`, `passkey-self/`, `passkey-company/`

The app runs with the passkey road on, as on macOS and Windows; on Linux it
offers the six-word road alone. The road is main's to say, in the chooser's
address, and the proof's own entry gives main that road (`startApp`'s
`accountRoad`), as the media proof's gives its grant, so the chooser here
is the one macOS and Windows have: the proof presses its Sign in with your passkey where it shows, and
from the device's pages goes to the sign-in page by its address. The app's account
window gets a virtual authenticator (CDP through its own
`webContents.debugger`) standing in for this computer's platform
authenticator, armed afresh for each ceremony with the passkeys this
computer holds; the person's answer in the app's "Sign in as" dialog is
stood in for, with what it offered recorded.

**`passkey/`** (shape `separate`). This computer's device is enrolled on the
six-word road first: a passkey a browser makes is approved only on a
device's own screen, so it is the trusted device for the passkey the
account window makes. The app is launched four times (`run.sh`):
`passkey`, killed right after a sign-in; `kept`, which then quits;
`closed`, where `cyfr` is then lost; and `left`, signed out for another CYFR.

| Row | What holds | What the row observes |
|---|---|---|
| `first_open` | a CYFR just connected opens at its root; sent from there to sign in, main refuses that and the chooser shows both ways on | the navigation to the root; main's decision on the redirect; both ways and Connect to another CYFR in sight |
| `device` | this computer's device is enrolled and opens Prism | Prism |
| `device_lock` | the device's Lock ends its session, the app forgets it, and the chooser shows both ways on | the cookie before and after; none left in the content's session; no sign-out |
| `passkeys_policy` | with a usable authenticator in the content window, both passkey calls in the CYFR's page and a frame are refused by the app's policy | each call's refusal naming the denied feature |
| `no_passkey` | Sign in opens the app's account window at the account service; with no passkey it says so and offers to make one | the account window's origin and page |
| `offer` | a passkey made in the account window returns to the CYFR's sign-in page, which shows its code | the code in the content window; the passkey the authenticator added |
| `matched_code` | the device's Your devices and its own window show the same code, and with the passphrase the passkey is added to the account | the code in both; the account's log at the directory, without that key before and with it after |
| `lock_forgets` | a lock forgets all of the content's storage, whatever the closing page was still writing or asking | the page writing a cookie until closed and a keepalive request of its sign-in page held past the lock, then answered; no cookie left afterwards; the ways on, nothing told |
| `passkey_sign_in` | the new passkey alone signs in: the account window's answer returns and Prism opens | Prism, a session, the account offered |
| `devices` | Your devices lists the passkey and how it signs in | the listed passkey |
| `confirm` | a key asked for in Prism is confirmed with the passkey in the account window | the confirmation's page; the key shown |
| `computer_lock` | the computer's lock and sleep leave the passkey's session as it was | as `connect/`'s |
| `sign_out` | Prism's Sign out ends the session and the chooser shows both ways on | the person's one sign-out answered with a redirect; the cookie before and after; the chooser, staying |
| `signed_out_root` | after signing out the CYFR opens to no one | its root given to the content window; main's refusal of the redirect to sign in; the ways on again; the old cookie refused |
| `sign_in_again` | after signing out only a fresh assertion opens Prism | the sign-in page by the chooser's button; a new session; the old cookie refused |
| `choose_cancel` | with two accounts' passkeys the app offers both; Cancel signs no one in; choosing @desk-a signs in as @desk-a | what the dialog offered; the page's refusal; Prism |
| `account_offline` | with the account service unreachable the account window opens the copy its worker stored, and that copy still carries main's refusal of a frame | the service's front taking `down` and answering none of it; the worker controlling the page it served; the engine's report of main's policy refusing the frame |
| `account_window` | main refuses a frame's load in the account window, and the CYFR's own page by navigation and by redirect, and either of those ends the ceremony | the engine's report of the policy main adds refusing that frame's address, apart from the account service's own policy, and nothing of it at the service's front; main's decisions; the window gone; nothing at the CYFR's front |
| `recovery` | the recovery code adds a passkey in the account window's recovery page, which returns to the sign-in and signs in | the passkey added; Prism |
| `wrong_window` | an answer made for another browser's sign-in signs no one in when given to the content window. This is the CYFR's binding of an answer to the browser that asked, holding in the app | the CYFR's refusal; the page's cookie opens nothing |
| `kept_after_kill`, `kept_after_quit`, `kept_after_loss` | killed right after a sign-in, quit, or left by `cyfr`'s loss, the app opens Prism by itself when it is launched again, signed in as before | Prism with nothing pressed; the first launch's cookie by its digest, its end where it was; that cookie opening a page |
| `renderer_killed` | a lost page is shown again and signs nobody out | as `connect/`'s |
| `kept_policy` | in a kept session too, both passkey calls are refused by the app's policy | each call's refusal naming the denied feature |
| `unanswered`, `try_again` | a page of the CYFR that did not load gives way to the chooser in the same window, naming the CYFR and offering it again; Try again asks `cyfr` first, then for the root, and opens Prism on the same sign-in | as `connect/`'s, with Try again in sight; the chooser's Connect before any load of the CYFR (a folder's CYFR refusing at it is the app's own tests', this client having no Docker); the first load of the CYFR after the press, and the front's request, the root; Prism connected under the same cookie |
| `chooser_refused` | Prism's page cannot send the window to the chooser, with a notice or by going back to the failure's, by a navigation, a redirect of a load of the CYFR's or its history | main's decision on each, the redirect answered by the content session's request hook in the CYFR's place; the same document staying |
| `chooser_history` | the engine's own move in the history, which asks main nothing, brings back the chooser's entry of a failure with no notice and no Try again | the document's navigation type, `back_forward`; the ways on in sight, no words and no Try again |
| `process_loss` | `cyfr`'s loss closes the content, tells the person and signs nobody out | the app's message; no sign-out; the cookie still opening a page |
| `system_quit_lost`, `system_quit` | ended by the system, after `cyfr`'s loss or at the chooser, the app quits, and never from inside the engine's `before-quit`, from which a quit is lost | SIGTERM to the app's own process; the app's own quit asked after that event returned; the engine's `quit` within 20 s; the process then gone by itself within 30 s (`launch.sh`) |
| `another_uncleared` | Connect to another CYFR does not advance past a clear that failed, and says so | the engine's clear made to fail; the ways on and the sentence; the proof's cookie and local storage item still kept |
| `another` | signed out, Connect to another CYFR clears all that was kept of the CYFR left, and main keeps to it no more | those marks there before; no cookie of any site and no item of that origin after; the form; main's refusal of that CYFR's page |

**`passkey-self/`** (shape `self`): `uncleared` (with the engine's clear
made to fail the Connect opens nothing and locks nothing: the same
chooser's form saying so, nothing of the CYFR loaded and `cyfr` running
on), `same_origin_hop` (the sign-in opens
the CYFR's own account page in the account window), `same_origin_sign_in`,
`passkeys_policy` (Prism's page, at the account pages' own origin, refused
both calls) and `home_paths` (the account window refuses the CYFR's own
page at that same origin, and the ceremony ends).

**`passkey-company/`** (shape `company`).

| Row | What holds | What the row observes |
|---|---|---|
| `account_road` | the passkey signs in, the CYFR's company page closes it in the app, and the chooser stays to send the person to a browser | the sentence's words and the chooser's way on, both in sight, with no move before it is pressed; no sign-out posted; no request starting a company sign-in and none at the issuer |
| `notice_kept` | a reload and a second lock over the chooser that is keeping a notice leave the notice there | the words, staying, after each, the second lock's own beside them (Connect to another CYFR, the engine's clear made to fail) |
| `device_road` | the device's page says the same once the CYFR refuses the device | the sentence on the device's page; the same two counts |

The chooser is `cyfr`'s own, with nothing stood in: on the passkey road it
stays with both ways on, and with a notice to show it stays on either road
until a way on is taken.

Every script with a `proof.js` has one row more, `unprinted`, in its
`app-NAME.log`: nothing the app printed carries an address's fragment or
query, or a credential. `scrub-lines.mjs` reads that output raw, and a
line the scrub would have cut fails the script. `unanswered` fails its
load at an address with a marker in its query and fragment, which the
engine's warning of that failure would print.

What the app takes for a CYFR's page not loaded is the engine's report of
a top frame's load of the CYFR failing, never a load given up (code -3);
that exception and a failure in each of main's states are held by the
app's own tests, on the engine stood in for. A page that loads and then
stops answering is reported by nothing, and stays.

A limit of the app: when main's load of a sign-in's answer is rejected,
as when the CYFR's page still had a load of its own pending, nobody is
signed in and nothing says so, and pressing Sign in again works. And a
notice not yet read is lost when the person quits.

Not here: the computer's real lock and sleep, Touch ID and Windows Hello (a
person at the machine), and macOS and Windows (`desktop-native`).

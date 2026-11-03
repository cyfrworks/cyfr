#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install proof: a clean Ubuntu 26.04 guest under QEMU/KVM, the QEMU
# inside a container built from this directory's Dockerfile, so the
# verification host installs nothing and joins no group. A person's terminal
# on the guest's own screen runs the install script as `curl ... | sh` pipes
# it, with production trust, then `cyfr init`, whose screen question's first
# answer shows CYFR on the screen, and `cyfr up`, and CYFR answers on its
# port. After a reboot labwc and Chrome run on tty1 and show the screen's
# own setup page (screen-setup.png): with the guest's isolated swtpm it asks
# for a six-digit PIN and seals the key in the chip; with --no-tpm it
# refuses six digits and takes the six-word passphrase it shows.
#
# Against a server with the device purposes the run goes on, typing on the
# guest's keyboard through QMP and reading what the box holds over SSH: the
# recovery code, I saved it, Prism; the lock after five minutes without
# input, a wrong PIN, the unlock; Prism's Lock; a change Prism confirms on
# this device (a command line's sign-in, cyfr login), cancelled first, then
# a wrong PIN, then the PIN again, and the command line signed in; the
# shell killed; its connection to CYFR severed past 60 s while a Prism page
# stays open; and Chrome's profile, copied while unlocked, put back before
# a reboot. After each lock, kill, cut and reboot the session cookie
# Chrome held (read from its profile, never kept in the evidence) is sent
# to sign in. Then a second, empty guest with a restore token, a
# replacement box, restores from the first box's recovery code on its own
# screen and makes a key of its own. Against a server without the device
# purposes everything past enrollment is PENDING, never passed. After
# `cyfr down` and another reboot of the first box CYFR stays down, the
# screen says why (screen-waiting.png), and Ctrl+Alt+F2 reaches a terminal:
#
#   tests/install-screen-proof/run.sh [--out DIR] [--no-tpm]
#
# After the script, this tree's cyfr takes the installed one's place, and
# after init this tree's server image (scripts/image.sh's) takes the
# release's in docker-compose.yml, stand-ins for a signed candidate, which
# results.txt says (lib.sh, candidate_build and candidate_server_use);
# candidate.txt records the tree's commit and both artifacts. Nothing reaches cyfr.run: each guest drops every packet to its
# addresses, and the cyfr.run stand-in (tests/registry-stand-in/standin.py)
# answers as its registry and directory (lib.sh, cyfr_run_guard and
# standin_start).
#
# Evidence goes under DIR (default a fresh
# /tmp/cyfr-evidence.install-screen.XXXXXX, printed, which scripts/janitor.sh
# removes a week later, its rule 5), each guest's in its own directory,
# clean/ and replacement/. The run's scratch directory,
# <run prefix>install-screen.XXXXXX under ${TMPDIR:-/tmp}, holds the guest's
# SSH key and password and the first box's recovery code: the teardown
# removes it, and scripts/janitor.sh's rule 1 removes a killed run's. The
# base image is the host's cache and the proof image is shared, each made
# by tests/install-screen-proof/prepare.sh, and this tree's server image
# is shared too, made by scripts/image.sh --undated app, all outside any
# lane before the run; without one the run exits 69, naming its command.
# The guests' overlays are in the Docker volume ${PROOF_RUN_PREFIX}disk.
#
# Every name the run gives Docker begins with PROOF_RUN_PREFIX, which
# scripts/heavy-check.sh sets; unset, it is scripts/lib/run-names.sh's prefix
# with this script's pid. It is a proof-lane check:
#   scripts/heavy-check.sh -p -t 3600 -- tests/install-screen-proof/run.sh
#
# Needs docker with the host's /dev/kvm, ssh, ssh-keygen, git, go, python3,
# timeout, flock, getent, and the guest's network: Ubuntu's archive,
# GitHub's releases, ghcr.io and Google's Chrome download. Stdout is framed
# `_START=<pid>` first and `_EXIT=<pid> <status>` last
# (scripts/await-task.sh). Exits 0 when every check passed; 1 when one
# failed or the run broke; 64 on usage or a refused prefix; 69 without a
# prerequisite; 130, 143 and 129 on INT, TERM and HUP.
set -uo pipefail

printf '_START=%s\n' "$$"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
missing() {
  printf '_EXIT=%s 69\n' "$$"
  exit 69
}
# shellcheck source=../../scripts/lib/run-names.sh
. "$ROOT/scripts/lib/run-names.sh" || missing
# shellcheck source=cleanup.sh
. "$HERE/cleanup.sh" || missing
# shellcheck source=lib.sh
. "$HERE/lib.sh" || missing
proof_traps

# The published release the guests install. This tree's server image runs
# under its docker-compose.yml and beside its locus images, so its stack
# files are this tree's.
INSTALL_VERSION=0.6.0-alpha.6

usage() { echo "usage: $0 [--out DIR] [--no-tpm]"; }
# The guest's TPM: an isolated swtpm of its own, or none (--no-tpm).
GUEST_TPM=swtpm
OUT=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --out)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      OUT=$2
      shift 2
      ;;
    --no-tpm)
      GUEST_TPM=none
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [ -z "${PROOF_RUN_PREFIX+set}" ]; then
  PROOF_RUN_PREFIX=$(run_names_prefix "$HERE") || exit 69
fi
if ! proof_prefix_valid "$PROOF_RUN_PREFIX"; then
  echo "install proof: PROOF_RUN_PREFIX '$PROOF_RUN_PREFIX' is not a run prefix (cyfr-<seed>-<pid>-, scripts/lib/run-names.sh); run it through scripts/heavy-check.sh, or leave it unset" >&2
  exit 64
fi
PROOF_PREFIX=$PROOF_RUN_PREFIX
# Read by lib.sh's helpers.
# shellcheck disable=SC2034
VOLUME="${PROOF_PREFIX}disk"

for tool in docker ssh ssh-keygen git go python3 timeout flock getent; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install proof: $tool is required" >&2; exit 69; }
done
[ -c /dev/kvm ] || { echo "install proof: this host has no /dev/kvm" >&2; exit 69; }
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo "install proof: no Docker daemon answers" >&2; exit 69; }

if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "/tmp/cyfr-evidence.install-screen.XXXXXX") || exit 1
else
  mkdir -p "$OUT" || exit 1
fi
OUT=$(cd "$OUT" && pwd)
PROOF_WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_PREFIX}install-screen.XXXXXX") || exit 1
WORK=$PROOF_WORK
echo "install proof: prefix $PROOF_PREFIX, evidence in $OUT"

transcript_has() { grep -qE -- "$2" "$GUEST_DIR/transcript-$1.txt"; }

# shell_page NAME: the screen's own page as the guest's loopback serves it,
# in GUEST_DIR/shell-NAME.html. A GET opens a page and changes nothing.
shell_page() { guest_ssh 'curl -s http://127.0.0.1:7340/' >"$GUEST_DIR/shell-$1.html" 2>&1; }

# shell_page_until NAME REGEX SECONDS: shell_page NAME, read each 3 s until
# it matches REGEX, within SECONDS; answers whether it did.
shell_page_until() {
  local closes
  budget "$3" || return 1
  closes=$((SECONDS + BUDGET))
  while :; do
    shell_page "$1"
    grep -qE -- "$2" "$GUEST_DIR/shell-$1.html" && return 0
    [ "$SECONDS" -lt "$closes" ] || return 1
    sleep 3
  done
}

# cookie_is in|out NAME: whether the home serves the cookie NAME (in) or
# sends it to sign in (out).
cookie_is() { case $(cookie_answer "$2") in "$1 "*) return 0 ;; esac; return 1; }

# Whether, within 60 s, the screen's Chrome is the one browser on the
# shell's pages and has run 8 s, its page drawn: a lock starts Chrome
# again, and keys typed before its window is up go nowhere.
screen_ready() {
  local closes
  budget 60 || return 1
  closes=$((SECONDS + BUDGET))
  until guest_ssh 'ps -u proof -o etimes=,args= | grep -- "-[-]app=http://127.0.0.1:7340/" | grep -v -- "--type=" |
      awk "{ n++; t = \$1 } END { exit !(n == 1 && t >= 8) }"'; do
    [ "$SECONDS" -lt "$closes" ] || return 1
    sleep 2
  done
}

# The PIN (or passphrase) the person types on the locked screen once its
# Chrome is up, then the time the unlock and Prism's page take.
screen_unlock() {
  check "the screen's Chrome is up on the lock page to take the PIN" screen_ready
  printf '%s\n' "$SECRET" | guest_keys || fail "QMP did not type"
  sleep 15
}

# Whether labwc runs on tty1 and Chrome beside it, within two minutes; the
# record is GUEST_DIR/screen.txt.
screen_runs() {
  GUEST_SSH_TIMEOUT=130 guest_ssh 'for n in $(seq 1 120); do
      pgrep -u proof -t tty1 -x labwc >/dev/null && pgrep -u proof -f /opt/google/chrome/chrome >/dev/null && break
      sleep 1
    done
    systemctl is-active cyfr-screen; ps -o user=,tty=,args= -C labwc; pgrep -u proof -f /opt/google/chrome/chrome | wc -l
    pgrep -u proof -t tty1 -x labwc >/dev/null && pgrep -u proof -f /opt/google/chrome/chrome >/dev/null' >"$GUEST_DIR/screen.txt" 2>&1
}

# After a boot with CYFR up: the screen, CYFR answering again, then the
# shell's next look at it.
screen_back() {
  screen_runs || fail "labwc and Chrome did not start on tty1 ($GUEST_DIR/screen.txt)"
  guest_ssh "for n in \$(seq 1 90); do curl -s -o /dev/null --max-time 2 http://localhost:4000/ && exit 0; sleep 2; done; exit 1" ||
    fail "CYFR did not come back after the reboot"
  sleep 25
}

# Reboots the guest and waits for its SSH, the cyfr.run guard's counters
# read first, as a boot clears them.
REBOOTS=0
guest_reboot() {
  local closes
  REBOOTS=$((REBOOTS + 1))
  cyfr_run_guarded "before-reboot-$REBOOTS" final
  guest_root 'systemd-run --on-active=2 systemctl reboot' || fail "the guest was not rebooted ($GUEST_DIR/root.txt)"
  sleep 15
  budget 300 || fail "the case's deadline came before the guest came back"
  closes=$((SECONDS + BUDGET))
  until guest_ssh true 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "the guest's SSH did not come back within $BUDGET s"
    sleep 2
  done
}

# box_install [RESTORE_TOKEN]: on the guest under way, the install script
# typed into tty1's terminal, cyfr init with its screen, this tree's server
# in the release's place and the cyfr.run stand-in in .env (with the
# restore token, for a replacement box), cyfr up, then a reboot: the screen
# starts, locked to its own pages, and the stand-in answers.
box_install() {
  local code running
  REBOOTS=0
  printf '%s (%s)\n' "$STAND_IN" "$OUT/candidate.txt" | tee -a "$GUEST_DIR/results.txt"
  cyfr_run_guard
  box_helpers
  guest_copy_in "$ROOT/scripts/install.sh" install.sh || fail "the install script was not copied into the guest"

  step "the install script, typed into tty1's terminal"
  pane_step script "cat install.sh | CYFR_VERSION=$INSTALL_VERSION sh" 900 'Install cosign\? \[y/N\]' y "$SUDO_PROMPT" @password
  check "the install script exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "it asks to install cosign once (asked ${PANE_ANSWERED[0]})" test "${PANE_ANSWERED[0]}" = 1
  check "it shows the commands before it asks" sh -c 'sed "/Install cosign/q" "$1" | grep -qx "  sudo apt-get update" && sed "/Install cosign/q" "$1" | grep -qx "  sudo apt-get install -y cosign"' sh "$GUEST_DIR/transcript-script.txt"
  check "the release's signature is verified" transcript_has script 'Signature verified'
  guest_ssh 'stat -c "%U %a" ~/.local/bin/cyfr' >"$GUEST_DIR/cyfr.txt" 2>&1
  check "cyfr is in ~/.local/bin, the person's" grep -qE '^proof 7[0-9]{2}$' "$GUEST_DIR/cyfr.txt"
  check "the install script linked cyfr onto PATH" transcript_has script 'sudo ln -sf /home/proof/.local/bin/cyfr /usr/local/bin/cyfr'
  pane_step_end script

  step "cyfr init on a machine without Docker, its screen question answered 1"
  guest_copy_in "$CANDIDATE_BIN" .local/bin/cyfr || fail "the candidate was not copied into the guest"
  # The guest's virtio display has no 3D; the product sets no renderer.
  guest_root 'mkdir -p /etc/systemd/system/cyfr-screen.service.d && printf "[Service]\nEnvironment=WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1\n" >/etc/systemd/system/cyfr-screen.service.d/proof.conf' ||
    fail "the guest's renderer was not set ($GUEST_DIR/root.txt)"
  pane_step init 'mkdir -p ~/cyfr && cd ~/cyfr && cyfr init' 1500 \
    'Install these requirements\? \(yes/no\)' yes "$SUDO_PROMPT" @password 'Choose 1 or 2 \[1\]' 1
  check "cyfr init exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "it asks \"Install these requirements?\" once" test "${PANE_ANSWERED[0]}" = 1
  check "sudo asks at most two passwords, the requirements' and the screen's (asked ${PANE_ANSWERED[1]})" test "${PANE_ANSWERED[1]}" -le 2
  check "init goes on through the docker group and asks the screen question once (asked ${PANE_ANSWERED[2]})" sh -c '[ "$1" = 1 ] && grep -qx "This machine has no desktop. Show CYFR on its screen?" "$2"' sh "${PANE_ANSWERED[2]}" "$GUEST_DIR/transcript-init.txt"
  check "it never asks how CYFR is reached" sh -c '! grep -q "How will you reach CYFR" "$1"' sh "$GUEST_DIR/transcript-init.txt"
  check "it shows the screen's commands" transcript_has init '^  systemctl enable cyfr-screen$'
  check "it says what it downloads" transcript_has init '^Downloading Chrome from Google \(about 110 MB\)$'
  check "it ends on the CYFR reached from this machine" transcript_has init '^CYFR is reached from this machine, at http://localhost:4000\.$'
  check "it gives the next step" transcript_has init '^Next: cyfr up, then sudo reboot\.$'
  check "nothing took the terminal: tty1's getty runs and the screen does not" guest_ssh 'systemctl is-active --quiet getty@tty1 && ! systemctl is-active --quiet cyfr-screen'
  check "Chrome's package left no .deb behind" guest_ssh '! ls /tmp/*.deb'
  pane_step_end init

  step "this tree's server in the release's place, and the cyfr.run stand-in named in .env"
  candidate_server_load
  standin_settings "${1:-}"

  step "cyfr up in the terminal that started before the group"
  pane_step up 'cd ~/cyfr && cyfr up' 900
  check "cyfr up exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "it says the reboot is next" transcript_has up '^Now run sudo reboot\. This screen opens setup at power-on\.$'
  check "it names no optional next steps" sh -c '! grep -q "Optional next steps" "$1"' sh "$GUEST_DIR/transcript-up.txt"
  pane_step_end up
  running=$(guest_root_out "docker inspect -f '{{.Image}}' cyfr")
  check "the cyfr container runs this tree's image ($running)" test "$running" = "$APP_IMAGE_ID"
  code=$(guest_ssh "curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/" 2>&1)
  check "CYFR answers on its port (HTTP $code)" sh -c '[ "$1" -ge 200 ] && [ "$1" -lt 400 ]' sh "$code"
  check "screenshot ready.png" guest_screenshot ready.png

  step "a reboot: the screen starts, locked to its own pages"
  guest_reboot
  screen_back
  cyfr_run_guarded boot
  standin_start boot
  if [ "$GUEST_TPM" = swtpm ]; then
    check "the guest has a TPM, its resource manager the tss group's" guest_ssh 'test -c /dev/tpmrm0 && [ "$(stat -c %G /dev/tpmrm0)" = tss ]'
    check "cyfr screen on joined the screen's account to tss" guest_ssh 'id -nG proof | tr " " "\n" | grep -qx tss'
  else
    check "the guest has no TPM" guest_ssh '! test -e /dev/tpmrm0'
  fi
  check "Chrome's managed policy saves no password and installs no extension" guest_ssh 'grep -q "\"PasswordManagerEnabled\": false" /etc/opt/chrome/policies/managed/cyfr-screen.json && grep -q "\"ExtensionInstallBlocklist\": \[\"\*\"\]" /etc/opt/chrome/policies/managed/cyfr-screen.json'
}

# The setup past enrollment, against a server with the device purposes:
# the recovery code shown and its name at the stand-in, "I saved it" and
# Prism, then each way the screen locks and what a lock leaves of the
# session, a change confirmed on the screen, and Chrome's profile copied.
screen_signed_in() {
  check "the recovery code is shown with its QR" grep -q '<svg' "$GUEST_DIR/shell-enrolled.html"
  sed -n 's/.*<p class="code">\(CYFR-[^<]*\)<\/p>.*/\1/p' "$GUEST_DIR/shell-enrolled.html" | head -n 1 | tr -d '\n' >"$WORK/recovery-code"
  check "the code is CYFR- and fourteen groups of eight letters and digits" grep -qE '^CYFR-[A-Z0-9]{8}([- ]?[A-Z0-9]{8}){13}$' "$WORK/recovery-code"
  guest_ssh 'cat ~/standin/state.json' >"$GUEST_DIR/standin-state-enrolled.json" 2>&1
  check "the name went to the cyfr.run stand-in, which holds alice" \
    python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if "alice" in d["names"] and d["logs"] else 1)' "$GUEST_DIR/standin-state-enrolled.json"
  check "screenshot screen-recovery.png" guest_screenshot screen-recovery.png
  printf '\n' | guest_keys || fail "QMP did not press I saved it"
  sleep 15
  check "screenshot screen-prism.png" guest_screenshot screen-prism.png
  shell_page saved
  check "the recovery code is gone from the screen once saved" sh -c '! grep -q "Your recovery code" "$1"' sh "$GUEST_DIR/shell-saved.html"
  check "the key record keeps no setup request once saved" guest_ssh '! grep -q "\"request_id\": *\"req_" ~/cyfr/.cyfr/screen/holder.json'
  check "Chrome holds the session cookie Prism opened with" screen_cookie prism
  check "the home serves that cookie on a page that needs a session" cookie_is in prism
  check "Chrome's profile is copied while Prism is open" guest_ssh "cp -a $SCREEN_PROFILE ~/chrome-copy"

  step "five minutes without input lock the screen"
  sleep 320
  shell_page idle
  check "the screen locked itself after five minutes without input" grep -q 'CYFR is locked' "$GUEST_DIR/shell-idle.html"
  check "screenshot screen-locked.png" guest_screenshot screen-locked.png
  check "after the idle lock the home sends that unlock's cookie to sign in" cookie_is out prism
  if [ "$GUEST_TPM" = swtpm ]; then
    printf '000000\n' | guest_keys || fail "QMP did not type"
    sleep 5
    check "screenshot screen-wrong-pin.png" guest_screenshot screen-wrong-pin.png
  fi
  screen_unlock
  check "screenshot screen-unlocked.png" guest_screenshot screen-unlocked.png
  check "the unlock reached Prism, the shell's page no longer shown" sh -c '! cmp -s "$1" "$2"' sh "$GUEST_DIR/screen-unlocked.png" "$GUEST_DIR/screen-locked.png"
  check "Chrome holds the new unlock's session cookie" screen_cookie unlocked
  check "the home serves it" cookie_is in unlocked

  step "Prism's Lock"
  screen_find lock && printf '\n' | guest_keys || fail "QMP did not press Prism's Lock"
  shell_page_until lock-prism 'CYFR is locked' 20
  check "Prism's Lock locked the screen, which says so" grep -q 'Locked\.' "$GUEST_DIR/shell-lock-prism.html"
  screen_ready
  check "screenshot screen-locked-prism.png" guest_screenshot screen-locked-prism.png
  check "after Prism's Lock the home sends that unlock's cookie to sign in" cookie_is out unlocked
  screen_unlock
  check "Chrome holds the next unlock's session cookie" screen_cookie confirming
  check "the home serves it" cookie_is in confirming

  screen_confirms
  screen_killed
  screen_severed
  screen_copied_profile
}

# A sensitive change confirmed on this screen: the sign-in of a command
# line on this box (cyfr login), whose approval in Prism needs a fresh
# confirmation. Prism's Confirm on this device opens the shell's own page,
# which draws the change CYFR holds; its Cancel signs nothing, a wrong PIN
# confirms nothing, and the PIN again confirms it, after which Prism
# approves the change and the command line is signed in. The home's record
# of the confirmation (its database, read as root) says which client gave
# it.
screen_confirms() {
  local link ref client closes
  step "a sensitive change confirmed on this screen: cyfr login approved in Prism"
  guest_ssh 'cd ~/cyfr && rm -f ~/login.log && setsid -f sh -c "~/.local/bin/cyfr login >~/login.log 2>&1; echo \"login exit status \$?\" >>~/login.log" </dev/null >/dev/null 2>&1' ||
    fail "cyfr login did not start"
  budget 30 || fail "the case's deadline came before cyfr login printed its link"
  closes=$((SECONDS + BUDGET))
  until guest_ssh 'grep -qE "https?://[^ ]+/cli#" ~/login.log' || [ "$SECONDS" -ge "$closes" ]; do sleep 1; done
  guest_ssh 'cat ~/login.log' >"$GUEST_DIR/login-asked.txt" 2>&1
  link=$(grep -oE 'https?://[^ ]+/cli#[^ ]+' "$GUEST_DIR/login-asked.txt" | head -n 1)
  check "cyfr login prints the link that approves it in Prism" test -n "$link"
  [ -n "$link" ] || return 0
  screen_open "$link" || fail "the screen's Chrome did not take the link"
  sleep 8
  check "screenshot screen-cli.png" guest_screenshot screen-cli.png
  screen_find approve last && printf '\n' | guest_keys || fail "QMP did not press Approve"
  sleep 6
  check "screenshot screen-confirm-asked.png" guest_screenshot screen-confirm-asked.png
  screen_find 'confirm on this device' && printf '\n' | guest_keys || fail "QMP did not press Confirm on this device"
  shell_page_until confirm-drawn 'Confirm on this screen' 20
  check "Confirm on this device opened the screen's own page, which draws the command line's approval CYFR holds" \
    sh -c 'grep -q "Confirm on this screen" "$1" && grep -q cli_approve "$1"' sh "$GUEST_DIR/shell-confirm-drawn.html"
  check "screenshot screen-confirm-drawn.png" guest_screenshot screen-confirm-drawn.png
  ref=$(sed -n 's/.*name="ref" value="\([^"]*\)".*/\1/p' "$GUEST_DIR/shell-confirm-drawn.html" | head -n 1)
  [ -n "$ref" ] || return 0

  step "Cancel signs nothing"
  # The PIN's field, Confirm, then Cancel.
  printf '\t\t\t\n' | guest_keys || fail "QMP did not press Cancel"
  sleep 5
  shell_page confirm-cancelled
  check "the screen says nothing was confirmed" grep -q 'Nothing was confirmed' "$GUEST_DIR/shell-confirm-cancelled.html"
  confirmation_state cancelled "$ref"
  check "the home holds the change still pending, confirmed by no client" \
    json_is "$GUEST_DIR/confirmation-cancelled.json" '{"state": "pending", "confirmed_client_id": null, "proof": null}'
  check "the command line still waits" guest_ssh '! grep -q "^Signed in" ~/login.log'

  step "a wrong PIN, then the PIN again, confirm it on this screen"
  # Back to Prism's tab, which still asks.
  guest_chord ctrl 1 || fail "QMP did not send the keys"
  sleep 2
  screen_find 'confirm on this device' && printf '\n' | guest_keys || fail "QMP did not press Confirm on this device"
  shell_page_until confirm-again 'Confirm on this screen' 20
  check "Confirm on this device draws it again" grep -q cli_approve "$GUEST_DIR/shell-confirm-again.html"
  printf '\t000000\n' | guest_keys || fail "QMP did not type"
  sleep 6
  shell_page confirm-wrong
  check "a wrong PIN confirms nothing: the screen says so and still asks" \
    sh -c 'grep -q "That is not this screen" "$1" && grep -q "Confirm on this screen" "$1"' sh "$GUEST_DIR/shell-confirm-wrong.html"
  confirmation_state wrong "$ref"
  check "the home still holds it pending" json_is "$GUEST_DIR/confirmation-wrong.json" '{"state": "pending", "confirmed_client_id": null}'
  printf '\t%s\n' "$SECRET" | guest_keys || fail "QMP did not type"
  sleep 8
  shell_page confirmed
  check "the screen confirmed it with the PIN again" grep -q 'Confirmed on this screen' "$GUEST_DIR/shell-confirmed.html"
  check "screenshot screen-confirmed.png" guest_screenshot screen-confirmed.png
  budget 60 || BUDGET=0
  closes=$((SECONDS + BUDGET))
  until guest_ssh 'grep -q "^login exit status" ~/login.log' || [ "$SECONDS" -ge "$closes" ]; do sleep 2; done
  guest_ssh 'cat ~/login.log' >"$GUEST_DIR/login-done.txt" 2>&1
  check "Prism approved it once confirmed: cyfr login signed in and exited 0" \
    sh -c 'grep -q "^Signed in" "$1" && grep -qx "login exit status 0" "$1"' sh "$GUEST_DIR/login-done.txt"
  confirmation_state confirmed "$ref"
  client=$(guest_ssh "python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[\"client_id\"])' ~/cyfr/.cyfr/screen/holder.json")
  check "the home records it confirmed by this screen's own client ($client) and consumed by the change" \
    json_is "$GUEST_DIR/confirmation-confirmed.json" "{\"state\": \"consumed\", \"confirmed_client_id\": \"$client\"}"
}

# confirmation_state NAME REF: the home's record of the confirmation REF,
# read from its SQLite database as root, in GUEST_DIR/confirmation-NAME.json.
confirmation_state() {
  guest_root_out "python3 -I /home/proof/box.py confirmation /home/proof/cyfr/data/cyfr.db $2" >"$GUEST_DIR/confirmation-$1.json"
}

# json_is FILE EXPECTED: whether the JSON object in FILE holds every field
# of the JSON object EXPECTED with its value.
json_is() {
  python3 -I -c '
import json, sys
got, want = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
sys.exit(0 if all(got.get(k) == v for k, v in want.items()) else 1)' "$1" "$2" 2>/dev/null
}

# The shell killed: the launcher starts it again, locked, and the session
# it held ends at the home within 60 s.
screen_killed() {
  local old new took
  step "the shell killed: the launcher starts it again, locked, and its session ends"
  old=$(guest_ssh 'pgrep -f "cyfr [s]creen shell"')
  guest_ssh 'pkill -KILL -f "cyfr [s]creen shell"' || fail "the shell was not killed"
  took=$(cookie_out_within confirming 75)
  check "the killed shell's session ended within 60 s (in ${took:-more than 75} s)" sh -c '[ -n "$1" ] && [ "$1" -le 60 ]' sh "$took"
  shell_page_until killed 'CYFR is locked' 30
  new=$(guest_ssh 'pgrep -f "cyfr [s]creen shell"')
  check "the launcher started the shell again (pid $old, then ${new:-none})" sh -c '[ -n "$2" ] && [ "$1" != "$2" ]' sh "$old" "$new"
  check "the shell started again locked" grep -q 'CYFR is locked' "$GUEST_DIR/shell-killed.html"
  screen_ready
  guest_ssh 'ps -u proof -o pid=,ppid=,args= | grep -E "[w]vkbd|[s]wayidle"' >"$GUEST_DIR/screen-children-killed.txt" 2>&1
  check "the killed shell left no keyboard or idle watch behind: one of each runs" \
    sh -c '[ "$(grep -c wvkbd "$1")" = 1 ] && [ "$(grep -c swayidle "$1")" = 1 ]' sh "$GUEST_DIR/screen-children-killed.txt"
  check "screenshot screen-killed.png" guest_screenshot screen-killed.png
}

# The shell's connection to CYFR severed: its packets, on the ports of its
# own connections alone, dropped both ways, while Prism's page in Chrome
# keeps its own. The session ends within 60 s; the shell, its ping
# unanswered, locks the screen as unreachable at its next report, which
# replaces the page held open, unless the home's end came first and sent
# that page to the sign-in page; and once the connection is back the
# screen is still locked, for the lost connection and not for idleness.
screen_severed() {
  local ports cut took seen closes
  step "the shell's connection to CYFR severed past 60 s while Prism's page stays open"
  screen_unlock
  check "Chrome holds the next unlock's session cookie" screen_cookie severed
  check "the home serves it" cookie_is in severed
  ports=$(guest_root_out "ss -tnpH state established '( dport = :4000 )' | grep '\"cyfr\",' | awk '{print \$3}' | sed 's/.*://'" | tr '\n' ' ')
  check "the shell holds its connection to CYFR (local ports $ports)" test -n "${ports// /}"
  cut=$(guest_ssh 'date +%s')
  guest_root "for p in $ports; do for c in INPUT OUTPUT; do for d in sport dport; do
      iptables -w -I \$c -p tcp --\$d \$p -m comment --comment cyfr-proof-sever -j DROP || exit 1
    done; done; done" || fail "the shell's connection was not severed ($GUEST_DIR/root.txt)"
  # A key that types nothing restarts the five minutes without input, so
  # no idle lock comes inside this case's waits.
  guest_chord shift || fail "QMP did not send the key"
  check "screenshot screen-severed.png" guest_screenshot screen-severed.png
  took=$(cookie_out_within severed 150)
  check "the severed shell's session ended within 60 s, a poll's 5 s aside (in ${took:-more than 150} s)" \
    sh -c '[ -n "$1" ] && [ "$1" -le 65 ]' sh "$took"
  budget 90 || BUDGET=0
  closes=$((SECONDS + BUDGET))
  until seen=$(guest_ssh "python3 -I ~/box.py visits $SCREEN_PROFILE $cut /login" 2>/dev/null) && [ -n "$seen" ] ||
    { shell_page severed-locked && grep -q "CYFR is locked" "$GUEST_DIR/shell-severed-locked.html"; } ||
    [ "$SECONDS" -ge "$closes" ]; do sleep 10; done
  check "Prism's page, held open past the session's end, went to the sign-in page or was replaced by the lock page (${seen:-locked})" \
    sh -c '[ -n "$1" ] || grep -q "CYFR is locked" "$2"' sh "$seen" "$GUEST_DIR/shell-severed-locked.html"
  check "screenshot screen-severed-after.png" guest_screenshot screen-severed-after.png
  guest_root_out 'iptables -w -L -v -n -x' >"$GUEST_DIR/severed-counters.txt"
  check "the cut dropped the shell's packets" \
    sh -c 'awk "/cyfr-proof-sever/ { n += \$1 } END { exit !(n > 0) }" "$1"' sh "$GUEST_DIR/severed-counters.txt"
  guest_root "for p in $ports; do for c in INPUT OUTPUT; do for d in sport dport; do
      iptables -w -D \$c -p tcp --\$d \$p -m comment --comment cyfr-proof-sever -j DROP
    done; done; done" || fail "the cut was not undone ($GUEST_DIR/root.txt)"

  step "the connection back: the shell finds its channel gone and locks"
  guest_chord shift || fail "QMP did not send the key"
  shell_page_until severed-back 'CYFR is locked' 180
  check "once the connection is back the shell locks, its channel gone, not for idleness" \
    sh -c 'grep -q "CYFR is locked" "$1" && ! grep -q "five minutes without use" "$1"' sh "$GUEST_DIR/shell-severed-back.html"
  screen_ready
  check "screenshot screen-severed-back.png" guest_screenshot screen-severed-back.png
}

# Chrome's profile, copied while Prism was open, put back while the screen
# is stopped, then a reboot: the screen boots locked, and the copy's
# cookie, the one Prism first opened with, opens nothing.
screen_copied_profile() {
  step "Chrome's profile copied while unlocked and put back, then a reboot"
  guest_root 'systemctl stop cyfr-screen' || fail "the screen was not stopped ($GUEST_DIR/root.txt)"
  guest_ssh "rm -rf $SCREEN_PROFILE && mv ~/chrome-copy $SCREEN_PROFILE" || fail "the copied profile was not put back"
  profile_cookie copy
  check "the copy holds the cookie Prism first opened with" test "${COOKIE_DIGEST[copy]:-none}" = "${COOKIE_DIGEST[prism]:-}"
  guest_reboot
  screen_back
  shell_page copied
  check "with the copied profile back the screen boots locked" grep -q 'CYFR is locked' "$GUEST_DIR/shell-copied.html"
  check "screenshot screen-copied.png" guest_screenshot screen-copied.png
  check "the copy's cookie opens nothing" cookie_is out copy
}

clean_install() {
  guest_boot clean 8192 40G
  tty1_login
  box_install
  check "screenshot screen-setup.png" guest_screenshot screen-setup.png
  shell_page setup
  check "the screen shows the shell's own setup page" grep -q 'Set up CYFR' "$GUEST_DIR/shell-setup.html"
  if [ "$GUEST_TPM" = swtpm ]; then
    check "with a chip it asks for a six-digit PIN" grep -q 'Choose a six-digit PIN' "$GUEST_DIR/shell-setup.html"
  else
    check "without a chip it asks for the passphrase it shows" grep -q 'no chip to keep a short PIN safe' "$GUEST_DIR/shell-setup.html"
  fi
  guest_ssh "sed -n 's/^CYFR_SETUP_TOKEN=//p' ~/cyfr/.env" >"$WORK/token" 2>&1
  guest_ssh 'ps -eo args' >"$GUEST_DIR/processes.txt" 2>&1
  check "the setup token is in no process's arguments" sh -c '[ -s "$1" ] && ! grep -qF "$(cat "$1")" "$2"' sh "$WORK/token" "$GUEST_DIR/processes.txt"
  check "no screen file holds the setup token" guest_ssh "! grep -rqF \"\$(sed -n 's/^CYFR_SETUP_TOKEN=//p' ~/cyfr/.env)\" --exclude-dir=chrome ~/cyfr/.cyfr/screen"

  step "setup on the screen, typed: a name and the PIN (or passphrase) twice"
  if [ "$GUEST_TPM" = none ]; then
    printf 'alice\t123456\t123456\n' | guest_keys || fail "QMP did not type"
    sleep 5
    shell_page six-digits
    check "without a chip six digits are refused" grep -q 'needs the six-word passphrase' "$GUEST_DIR/shell-six-digits.html"
    check "a refused PIN made no key" guest_ssh '! test -e ~/cyfr/.cyfr/screen/holder.json'
    SECRET=$(sed -n 's/.*<p class="code">\([a-z ]*\)<\/p>.*/\1/p' "$GUEST_DIR/shell-six-digits.html" | head -n 1)
    check "the page shows a six-word passphrase" sh -c '[ "$(printf %s "$1" | wc -w)" = 6 ]' sh "$SECRET"
    KIND=software
  else
    SECRET=$(printf '%06d' $((RANDOM % 1000000)))
    KIND=chip
  fi
  printf 'alice\t%s\t%s\n' "$SECRET" "$SECRET" | guest_keys || fail "QMP did not type"
  sleep 15
  guest_ssh 'stat -c %a ~/cyfr/.cyfr/screen/holder.json && cat ~/cyfr/.cyfr/screen/holder.json' >"$GUEST_DIR/holder.txt" 2>&1
  check "the key record is the account's alone, mode 600" sh -c '[ "$(head -n 1 "$1")" = 600 ]' sh "$GUEST_DIR/holder.txt"
  check "the key is held by the $KIND holder" grep -qE "\"kind\": *\"$KIND\"" "$GUEST_DIR/holder.txt"
  check "the key record holds neither the PIN nor the passphrase" sh -c '! grep -qF -- "$1" "$2"' sh "$SECRET" "$GUEST_DIR/holder.txt"
  guest_ssh "python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[\"public_key\"])' ~/cyfr/.cyfr/screen/holder.json" >"$WORK/first-key" 2>/dev/null
  check "screenshot screen-enrolled.png" guest_screenshot screen-enrolled.png
  shell_page enrolled
  if grep -q 'Your recovery code' "$GUEST_DIR/shell-enrolled.html"; then
    screen_signed_in
  elif grep -q 'Finish setting up' "$GUEST_DIR/shell-enrolled.html"; then
    # A server without the device purposes (S1a) answers no enrollment.
    record PENDING "enrollment, the recovery code, Prism, lock, unlock, confirmation and the replacement box need a candidate server with the device purposes; what this one answered is on screen-enrolled.png"
  else
    check "the enrolled screen shows the recovery code (it shows shell-enrolled.html)" false
  fi
  guest_ssh 'cat ~/standin/state.json' >"$WORK/standin-state.json" 2>/dev/null && cp "$WORK/standin-state.json" "$GUEST_DIR/standin-state.json"

  step "cyfr down, then a reboot: CYFR stays down and the screen says why"
  guest_ssh 'cd ~/cyfr && ~/.local/bin/cyfr down' >"$GUEST_DIR/down.txt" 2>&1 || fail "cyfr down failed ($GUEST_DIR/down.txt)"
  guest_reboot
  screen_runs || fail "labwc and Chrome did not come back on tty1 ($GUEST_DIR/screen.txt)"
  sleep 20
  check "screenshot screen-waiting.png" guest_screenshot screen-waiting.png
  check "the waiting page is on the screen, not the setup page" sh -c '! cmp -s "$1" "$2"' sh "$GUEST_DIR/screen-waiting.png" "$GUEST_DIR/screen-setup.png"
  check "cyfr down stayed effective: no container runs" guest_ssh '[ -z "$(docker ps -q)" ]'
  check "CYFR does not answer" guest_ssh '! curl -s -o /dev/null --max-time 2 http://localhost:4000/'
  guest_ssh 'cat /sys/class/tty/tty0/active' >"$GUEST_DIR/vt-before.txt" 2>&1
  check "the screen is on tty1" grep -qx tty1 "$GUEST_DIR/vt-before.txt"
  guest_qmp send-key '{"keys": [{"type": "qcode", "data": "ctrl"}, {"type": "qcode", "data": "alt"}, {"type": "qcode", "data": "f2"}]}' >/dev/null || fail "QMP did not send the keys"
  sleep 5
  guest_ssh 'cat /sys/class/tty/tty0/active; systemctl is-active getty@tty2' >"$GUEST_DIR/vt-after.txt" 2>&1
  check "Ctrl+Alt+F2 reaches a terminal on tty2" sh -c '[ "$(cat "$1")" = "tty2
active" ]' sh "$GUEST_DIR/vt-after.txt"
  check "screenshot screen-terminal.png" guest_screenshot screen-terminal.png
  cyfr_run_guarded end final
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict clean
}

# A replacement box: a second, empty guest whose .env holds a restore
# token, with the first box's directory at the stand-in. Its screen offers
# the restore, takes the first box's recovery code and a new PIN (or the
# passphrase it shows), makes a key of its own under its own chip, and
# opens Prism as the person restored.
replacement_restore() {
  local token key entries
  if ! [ -s "$WORK/recovery-code" ] || ! [ -s "$WORK/standin-state.json" ]; then
    printf 'replacement: pending, the restore onto a replacement box needs the first box to reach its recovery code\n' | tee -a "$OUT/results.txt"
    return 0
  fi
  guest_boot replacement 8192 40G
  tty1_login
  token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  box_install "$token"
  check "screenshot screen-restore.png" guest_screenshot screen-restore.png
  shell_page restore
  check "with a restore token the screen offers the restore" grep -q 'Restore onto this box' "$GUEST_DIR/shell-restore.html"

  step "the restore on the screen, typed: the first box's recovery code and a new PIN (or passphrase) twice"
  if [ "$GUEST_TPM" = none ]; then
    SECRET=$(sed -n 's/.*<p class="code">\([a-z ]*\)<\/p>.*/\1/p' "$GUEST_DIR/shell-restore.html" | head -n 1)
    KIND=software
  else
    SECRET=$(printf '%06d' $((RANDOM % 1000000)))
    KIND=chip
  fi
  { cat "$WORK/recovery-code"; printf '\t%s\t%s\n' "$SECRET" "$SECRET"; } | guest_keys || fail "QMP did not type"
  # The restore, the directory's recovery and the enrollment end when the
  # page changes.
  shell_page_until restored '<h1>(CYFR|Your|Finish)' 150
  if grep -q 'Your recovery code' "$GUEST_DIR/shell-restored.html"; then
    printf '\n' | guest_keys || fail "QMP did not press I saved it"
  fi
  sleep 15
  check "screenshot screen-restored.png" guest_screenshot screen-restored.png
  check "the restore finished: the screen no longer offers it" sh -c '! grep -q "Restore onto this box" "$1"' sh "$GUEST_DIR/shell-restored.html"
  guest_ssh 'stat -c %a ~/cyfr/.cyfr/screen/holder.json && cat ~/cyfr/.cyfr/screen/holder.json' >"$GUEST_DIR/holder.txt" 2>&1
  check "the key is held by the $KIND holder" grep -qE "\"kind\": *\"$KIND\"" "$GUEST_DIR/holder.txt"
  key=$(guest_ssh "python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[\"public_key\"])' ~/cyfr/.cyfr/screen/holder.json" 2>/dev/null)
  check "the replacement box made a key of its own, not the first box's" \
    sh -c 'key="^[A-Za-z0-9+/_-]{43}=?$"; printf "%s\n" "$1" | grep -qE "$key" && grep -qE "$key" "$2" && [ "$1" != "$(cat "$2")" ]' sh "$key" "$WORK/first-key"
  check "Chrome holds the restored person's session cookie" screen_cookie restored
  check "the home serves it" cookie_is in restored
  guest_ssh 'cat ~/standin/state.json' >"$GUEST_DIR/standin-state.json" 2>&1
  entries='import json, sys; print(sum(len(log["entries"]) for log in json.load(open(sys.argv[1]))["logs"].values()))'
  check "the identity's log at the stand-in grew by the restore's recovery" \
    sh -c '[ "$(python3 -I -c "$1" "$2")" -gt "$(python3 -I -c "$1" "$3")" ]' sh "$entries" "$GUEST_DIR/standin-state.json" "$WORK/standin-state.json"
  cyfr_run_guarded end final
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict replacement
}

status=0
proof_image_use
proof_kvm_preflight
proof_base_verify
proof_seed
candidate_build
candidate_server_use
clean_install || status=$?
replacement_restore || status=$?
echo
echo "install proof: $(tr '\n' ';' <"$OUT/results.txt" 2>/dev/null) evidence in $OUT"
exit "$status"

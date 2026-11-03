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
# refuses six digits and takes the six-word passphrase it shows. Against a
# server with the device purposes the run goes on to the recovery code,
# Prism, the idle lock and the unlock; against one without, it records
# that part PENDING, never passed. After `cyfr down` and another
# reboot CYFR stays down, the screen says why (screen-waiting.png), and
# Ctrl+Alt+F2 reaches a terminal:
#
#   tests/install-screen-proof/run.sh [--out DIR] [--no-tpm]
#
# After the script, this tree's cyfr takes the installed one's place, a
# stand-in for a signed candidate, which results.txt says (lib.sh,
# candidate_build).
#
# Evidence goes under DIR (default a fresh
# /tmp/cyfr-evidence.install-screen.XXXXXX, printed, which scripts/janitor.sh
# removes a week later, its rule 5). The run's scratch directory,
# <run prefix>install-screen.XXXXXX under ${TMPDIR:-/tmp}, holds the guest's
# SSH key and password: the teardown removes it, and scripts/janitor.sh's
# rule 1 removes a killed run's. The base image is the host's cache and the
# proof image is shared, each made by tests/install-screen-proof/prepare.sh
# outside any lane; without them the run exits 69, naming prepare.sh. The
# guest's overlay is in the Docker volume ${PROOF_RUN_PREFIX}disk.
#
# Every name the run gives Docker begins with PROOF_RUN_PREFIX, which
# scripts/heavy-check.sh sets; unset, it is scripts/lib/run-names.sh's prefix
# with this script's pid. It is a proof-lane check:
#   scripts/heavy-check.sh -p -t 3600 -- tests/install-screen-proof/run.sh
#
# Needs docker with the host's /dev/kvm, ssh, ssh-keygen, git, go, python3,
# timeout, flock, and the guest's network: Ubuntu's archive and GitHub's
# releases. Stdout is framed `_START=<pid>` first and `_EXIT=<pid> <status>`
# last (scripts/await-task.sh). Exits 0 when every check passed; 1 when one
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

INSTALL_VERSION=0.6.0-alpha.5

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

for tool in docker ssh ssh-keygen git go python3 timeout flock; do
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

# The setup past enrollment, against a server with the device purposes:
# the recovery code shown, "I saved it", Prism, the lock after five minutes
# without input, a wrong PIN said, and the unlock.
screen_signed_in() {
  check "the recovery code is shown with its QR" grep -q '<svg' "$GUEST_DIR/shell-enrolled.html"
  check "screenshot screen-recovery.png" guest_screenshot screen-recovery.png
  printf '\n' | guest_keys || fail "QMP did not press I saved it"
  sleep 15
  check "screenshot screen-prism.png" guest_screenshot screen-prism.png
  shell_page saved
  check "the recovery code is gone from the screen once saved" sh -c '! grep -q "Your recovery code" "$1"' sh "$GUEST_DIR/shell-saved.html"
  check "the key record keeps no setup request once saved" guest_ssh '! grep -q "\"request_id\": *\"req_" ~/cyfr/.cyfr/screen/holder.json'
  step "five minutes without input lock the screen"
  sleep 320
  shell_page idle
  check "the screen locked itself after five minutes without input" grep -q 'CYFR is locked' "$GUEST_DIR/shell-idle.html"
  check "screenshot screen-locked.png" guest_screenshot screen-locked.png
  if [ "$GUEST_TPM" = swtpm ]; then
    printf '000000\n' | guest_keys || fail "QMP did not type"
    sleep 5
    check "screenshot screen-wrong-pin.png" guest_screenshot screen-wrong-pin.png
  fi
  printf '%s\n' "$SECRET" | guest_keys || fail "QMP did not type"
  sleep 15
  check "screenshot screen-unlocked.png" guest_screenshot screen-unlocked.png
  check "the unlock reached Prism, the shell's page no longer shown" sh -c '! cmp -s "$1" "$2"' sh "$GUEST_DIR/screen-unlocked.png" "$GUEST_DIR/screen-locked.png"
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

# Reboots the guest and waits for its SSH.
guest_reboot() {
  local closes
  guest_root 'systemd-run --on-active=2 systemctl reboot' || fail "the guest was not rebooted ($GUEST_DIR/root.txt)"
  sleep 15
  budget 300 || fail "the case's deadline came before the guest came back"
  closes=$((SECONDS + BUDGET))
  until guest_ssh true 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "the guest's SSH did not come back within $BUDGET s"
    sleep 2
  done
}

clean_install() {
  local code
  candidate_build
  guest_boot clean 8192 40G
  tty1_login
  printf '%s (%s)\n' "$STAND_IN" "$OUT/candidate.txt" | tee -a "$GUEST_DIR/results.txt"
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

  step "cyfr up in the terminal that started before the group"
  pane_step up 'cd ~/cyfr && cyfr up' 900
  check "cyfr up exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "it says the reboot is next" transcript_has up '^Now run sudo reboot\. This screen opens setup at power-on\.$'
  check "it names no optional next steps" sh -c '! grep -q "Optional next steps" "$1"' sh "$GUEST_DIR/transcript-up.txt"
  pane_step_end up
  code=$(guest_ssh "curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/" 2>&1)
  check "CYFR answers on its port (HTTP $code)" sh -c '[ "$1" -ge 200 ] && [ "$1" -lt 400 ]' sh "$code"
  check "screenshot ready.png" guest_screenshot ready.png

  step "a reboot: the screen starts, locked to its own pages"
  guest_reboot
  screen_runs || fail "labwc and Chrome did not start on tty1 ($GUEST_DIR/screen.txt)"
  # CYFR's own restart, then the shell's next look, then the page.
  guest_ssh "for n in \$(seq 1 90); do curl -s -o /dev/null --max-time 2 http://localhost:4000/ && exit 0; sleep 2; done; exit 1" ||
    fail "CYFR did not come back after the reboot"
  sleep 25
  if [ "$GUEST_TPM" = swtpm ]; then
    check "the guest has a TPM, its resource manager the tss group's" guest_ssh 'test -c /dev/tpmrm0 && [ "$(stat -c %G /dev/tpmrm0)" = tss ]'
    check "cyfr screen on joined the screen's account to tss" guest_ssh 'id -nG proof | tr " " "\n" | grep -qx tss'
  else
    check "the guest has no TPM" guest_ssh '! test -e /dev/tpmrm0'
  fi
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
  check "screenshot screen-enrolled.png" guest_screenshot screen-enrolled.png
  shell_page enrolled
  if grep -q 'Your recovery code' "$GUEST_DIR/shell-enrolled.html"; then
    screen_signed_in
  else
    # A server without the device purposes (S1a) answers no enrollment.
    record PENDING "enrollment, the recovery code, Prism, lock, unlock and confirmation need a candidate server with the device purposes; this one answered: $(sed -n 's/.*<p class="notice" role="status">\([^<]*\)<.*/\1/p' "$GUEST_DIR/shell-enrolled.html" | head -n 1)"
  fi

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
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict clean
}

status=0
proof_image_use
proof_kvm_preflight
proof_base_verify
proof_seed
clean_install || status=$?
echo
echo "install proof: $(tr '\n' ';' <"$OUT/results.txt" 2>/dev/null) evidence in $OUT"
exit "$status"

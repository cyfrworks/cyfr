#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof: real Ubuntu 26.04 guests under QEMU/KVM,
# the QEMU inside a container built from this directory's Dockerfile, so
# the verification host installs nothing and joins no group. One case per
# invocation:
#
#   tests/install-screen-proof/run.sh --case N [--part PART] [--out DIR]
#
# Case 1, install missing Ubuntu requirements. First QEMU in the container
# creates a KVM machine (kvm-preflight.txt); nothing else runs without it.
# Then each part boots a fresh guest from the pinned cloud image, records
# that QEMU runs it with KVM and that it reached its login prompt, signs
# the test account in on tty1 and starts tmux there, and types the
# installer into that terminal as `cat install.sh | CYFR_VERSION=0.6.0-alpha.5 sh`,
# the pipe `curl ... | sh` makes, with production trust and no bypass
# variable, answering what it asks. PART is
#   trunk      origin/main's scripts/install.sh, cosign absent: it refuses,
#              cosign being required, asks no password and changes no
#              package (s1-trunk.png).
#   candidate  this tree's scripts/install.sh, copied as the part starts:
#              it previews, asks "Install these requirements?" (answered
#              y), asks the sudo password once, installs cosign from
#              Ubuntu and nothing else, verifies the release's signature
#              and checksum and installs a root-owned /usr/local/bin/cyfr
#              that reports 0.6.0-alpha.5 (s1-bootstrap.png). Afterwards
#              `sudo -n true` fails, in that terminal and over SSH. A
#              script without an `install policy` block is not run.
#   all        (default) trunk, then candidate, each in its own guest.
# Case 2, cyfr init on a machine without Docker: what sudo-rs's
# per-command -k leaves, with and without a prior login; init's preview,
# one question and one password, the continued init, newgrp before cyfr
# up, Docker 28+, Compose v2, cgroup v2 and AppArmor, the account's
# project files, no reusable sudo login after it, and a second init that
# shows nothing and makes no apt transaction (s1-ready.png). Case 3, its
# refusals and retries: declined, each of the three locks held, offline,
# interrupted while dpkg unpacks and retried, then the terminal that
# predates the group (s1-retry.png). Case 4, an earlier cyfr in
# ~/.local/bin: the installer's migration declined, then accepted
# (s1-path.png).
#
# Evidence goes under DIR (default a fresh
# /tmp/cyfr-install-screen-case<N>.XXXXXX, printed), which keeps it: the
# image's build log, the KVM preflight and the base image's verification,
# then one directory per part, which must not exist yet, holding
# results.txt, kvm.txt (QEMU's KVM state, version, descriptors and command
# line), guest.txt, cloud-init.txt, the package lists before and after,
# the installer's provenance and typed line (installer.txt), the terminal's
# transcript, the serial console, QEMU's log, the journal, apt's history
# and the named screenshots. DIR/results.txt holds one verdict per part.
# Only disks are on disk: the base image is the host's cache, which
# tests/install-screen-proof/fetch-base.sh fills and verifies outside any
# lane and the run mounts read-only and verifies again with no network,
# and each guest's overlay is in the Docker volume ${PROOF_RUN_PREFIX}disk.
# The run downloads no base image: without the cache it exits 69.
#
# Every name the run gives Docker begins with PROOF_RUN_PREFIX, which
# scripts/heavy-check.sh sets; unset, it is scripts/lib/run-names.sh's
# prefix with this script's pid, and set to anything but such a prefix it
# is refused. The run makes the image ${PROOF_RUN_PREFIX}qemu:proof, the
# volume and the containers ${PROOF_RUN_PREFIX}kvm, ...verify and
# ...qemu-<part>, and removes them on every exit (cleanup.sh). It is a
# proof-lane check:
#   scripts/heavy-check.sh -p -t 3600 -- tests/install-screen-proof/run.sh --case 1
#
# Needs docker with the host's /dev/kvm, ssh, ssh-keygen, git, python3,
# timeout, the base image's cache, and the guests' network: Ubuntu's
# archive and GitHub's releases.
#
# Stdout is framed `_START=<pid>` first and `_EXIT=<pid> <status>` last
# (scripts/await-task.sh). Exits 0 when every check of every part run
# passed; 1 when one failed or the run broke; 77 when the parts asked for
# passed but the candidate was not run, its script not ready; 64 on usage
# or a refused prefix; 69 without a prerequisite; 130, 143 and 129 on INT,
# TERM and HUP.
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

usage() { echo "usage: $0 --case N [--part trunk|candidate|all] [--out DIR]"; }
CASE="" PART="" OUT=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --case | --part | --out)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      case $1 in --case) CASE=$2 ;; --part) PART=$2 ;; --out) OUT=$2 ;; esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
case $CASE in
  1)
    PART=${PART:-all}
    case $PART in trunk | candidate | all) ;; *) usage >&2; exit 64 ;; esac
    ;;
  2 | 3 | 4) [ -z "$PART" ] || { usage >&2; exit 64; } ;;
  *) usage >&2; exit 64 ;;
esac

if [ -z "${PROOF_RUN_PREFIX+set}" ]; then
  PROOF_RUN_PREFIX=$(run_names_prefix "$HERE") || exit 69
fi
if ! proof_prefix_valid "$PROOF_RUN_PREFIX"; then
  echo "install-screen proof: PROOF_RUN_PREFIX '$PROOF_RUN_PREFIX' is not a run prefix (cyfr-<seed>-<pid>-, scripts/lib/run-names.sh); run it through scripts/heavy-check.sh, or leave it unset" >&2
  exit 64
fi
PROOF_PREFIX=$PROOF_RUN_PREFIX
# Read by lib.sh's helpers.
# shellcheck disable=SC2034
IMAGE="${PROOF_PREFIX}qemu:proof"
# shellcheck disable=SC2034
VOLUME="${PROOF_PREFIX}disk"

for tool in docker ssh ssh-keygen git python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install-screen proof: $tool is required" >&2; exit 69; }
done
[ -c /dev/kvm ] || { echo "install-screen proof: this host has no /dev/kvm" >&2; exit 69; }
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo "install-screen proof: no Docker daemon answers" >&2; exit 69; }

if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-install-screen-case$CASE.XXXXXX") || exit 1
else
  mkdir -p "$OUT" || exit 1
fi
OUT=$(cd "$OUT" && pwd)
PROOF_WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_PREFIX}install-screen.XXXXXX") || exit 1
WORK=$PROOF_WORK
echo "install-screen proof: case $CASE, part $PART, prefix $PROOF_PREFIX, evidence in $OUT"

# ---------------------------------------------------------------------------
# Case 1
# ---------------------------------------------------------------------------

# The line typed at the prompt for the script $1 in the guest's home:
# piped to sh as `curl ... | sh` pipes it, its exit status echoed after.
install_line() {
  printf 'cat %s | CYFR_VERSION=%s sh; echo "installer exit status $?"' "$1" "$INSTALL_VERSION"
}

# The installer's exit status, from the transcript's last echo of it.
installer_status() {
  sed -n 's/^installer exit status \([0-9][0-9]*\).*/\1/p' "$GUEST_DIR/transcript.txt" | tail -n 1
}

candidate_ready() {
  grep -qi 'install policy' "$ROOT/scripts/install.sh"
}

guest_no_cyfr() {
  guest_ssh 'test ! -e /usr/local/bin/cyfr && test ! -e "$HOME/.local/bin/cyfr"'
}

case_1_trunk() {
  local status
  git -C "$ROOT" show origin/main:scripts/install.sh >"$WORK/install-trunk.sh" ||
    fail "origin/main has no scripts/install.sh here"
  guest_boot trunk 2048 20G
  tty1_login
  guest_packages packages-before.txt
  check "trunk: cosign is not installed before the run" guest_cosign_absent
  {
    echo "script: origin/main:scripts/install.sh at $(git -C "$ROOT" rev-parse origin/main)"
    echo "sha256: $(sha256sum <"$WORK/install-trunk.sh" | cut -d ' ' -f 1)"
    echo "typed: $(install_line install.sh)"
  } >"$GUEST_DIR/installer.txt"
  guest_copy_in "$WORK/install-trunk.sh" install.sh || fail "the trunk script was not copied into the guest"

  step "trunk: the installer, typed into tty1's terminal"
  pane_type "$(install_line install.sh)" || fail "the installer's line was not typed"
  if ! pane_converse 600 '^installer exit status [0-9]+' "$SUDO_PROMPT" @password; then
    pane_save transcript.txt
    guest_screenshot s1-trunk.png || true
    fail "trunk: the installer did not finish within 600 s ($GUEST_DIR/transcript.txt)"
  fi
  pane_save transcript.txt
  status=$(installer_status)
  check "trunk: the installer exits 1 (it exited ${status:-unknown})" test "$status" = 1
  check "trunk: it refuses because cosign is required" \
    grep -qF "Error: cosign is required to verify that checksums.txt is the release workflow's" "$GUEST_DIR/transcript.txt"
  check "trunk: no password was asked (asked ${PANE_ANSWERED[0]})" test "${PANE_ANSWERED[0]}" = 0
  check "trunk: no cyfr was installed" guest_no_cyfr
  check "trunk: cosign is still not installed" guest_cosign_absent
  check "trunk: screenshot s1-trunk.png" guest_screenshot s1-trunk.png
  guest_packages packages-after.txt
  check "trunk: no package changed" cmp -s "$GUEST_DIR/packages-before.txt" "$GUEST_DIR/packages-after.txt"
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict trunk
}

# Whether the transcript's lines before the question name $1.
preview_names() {
  sed '/Install these requirements?/q' "$GUEST_DIR/transcript.txt" | grep -v 'installer exit status' | grep -q -- "$1"
}

cosign_from_ubuntu() {
  grep -q '^ii ' "$GUEST_DIR/cosign.txt" &&
    awk '/\*\*\*/ { getline; print; exit }' "$GUEST_DIR/cosign.txt" | grep -qE 'https?://[a-z.]*ubuntu\.com/ubuntu'
}

# Whether the only package change is cosign's installation.
only_cosign_added() {
  diff "$GUEST_DIR/packages-before.txt" "$GUEST_DIR/packages-after.txt" >"$GUEST_DIR/packages-changed.txt"
  [ "$(grep -c '^[<>]' "$GUEST_DIR/packages-changed.txt")" = 1 ] &&
    grep -qE $'^> cosign\t[^\t]+\tii $' "$GUEST_DIR/packages-changed.txt"
}

# Whether the probe line $1, `sudo -n status N`, says sudo refused.
probe_failed() {
  [ -n "$1" ] && [ "${1##* }" != 0 ]
}

cyfr_root_owned() {
  local owner mode kind
  read -r owner mode kind <<<"$(sed -n 1p "$GUEST_DIR/cyfr.txt")"
  [ "$owner" = root:root ] && [ "$kind" = "regular file" ] && [[ $mode =~ ^[0-7]{3,4}$ ]] &&
    [ $((8#$mode & 8#022)) = 0 ]
}

case_1_candidate() {
  local status prompts probe
  cp "$ROOT/scripts/install.sh" "$WORK/install-candidate.sh" || fail "the candidate script was not copied"
  guest_boot candidate 2048 20G
  tty1_login
  guest_packages packages-before.txt
  check "candidate: cosign is not installed before the run" guest_cosign_absent
  {
    echo "script: $ROOT/scripts/install.sh as the part started, the worktree at $(git -C "$ROOT" rev-parse HEAD)"
    echo "git status: $(git -C "$ROOT" status --short -- scripts/install.sh)"
    echo "sha256: $(sha256sum <"$WORK/install-candidate.sh" | cut -d ' ' -f 1)"
    echo "typed: $(install_line install.sh)"
  } >"$GUEST_DIR/installer.txt"
  guest_copy_in "$WORK/install-candidate.sh" install.sh || fail "the candidate script was not copied into the guest"

  step "candidate: the installer, typed into tty1's terminal"
  pane_type "$(install_line install.sh)" || fail "the installer's line was not typed"
  if ! pane_converse 900 '^installer exit status [0-9]+' 'Install these requirements\?' y "$SUDO_PROMPT" @password; then
    pane_save transcript.txt
    guest_screenshot s1-bootstrap.png || true
    fail "candidate: the installer did not finish within 900 s, or asked a question a fourth time ($GUEST_DIR/transcript.txt)"
  fi
  pane_save transcript.txt
  status=$(installer_status)
  prompts=$(grep -cE -- "$SUDO_PROMPT" "$GUEST_DIR/transcript.txt")
  echo "sudo password prompts: $prompts in the transcript, ${PANE_ANSWERED[1]} answered" >>"$GUEST_DIR/installer.txt"
  check "candidate: the installer exits 0 (it exited ${status:-unknown})" test "$status" = 0
  check "candidate: it asks \"Install these requirements?\" once (asked ${PANE_ANSWERED[0]})" test "${PANE_ANSWERED[0]}" = 1
  check "candidate: its preview, before the question, names cosign" preview_names cosign
  check "candidate: sudo asks the password exactly once ($prompts prompts, ${PANE_ANSWERED[1]} answered)" \
    test "$prompts/${PANE_ANSWERED[1]}" = 1/1
  check "candidate: the release's signature is verified" grep -q 'Signature verified' "$GUEST_DIR/transcript.txt"
  check "candidate: the archive's checksum is verified" grep -q 'Checksum verified' "$GUEST_DIR/transcript.txt"
  guest_ssh 'dpkg-query -W -f "\${db:Status-Abbrev} \${Version}\n" cosign; apt-cache policy cosign; command -v cosign' \
    >"$GUEST_DIR/cosign.txt" 2>&1
  check "candidate: cosign is installed from Ubuntu's archive" cosign_from_ubuntu
  guest_ssh 'stat -c "%U:%G %a %F" /usr/local/bin/cyfr; /usr/local/bin/cyfr --version' >"$GUEST_DIR/cyfr.txt" 2>&1
  check "candidate: /usr/local/bin/cyfr is a regular file root owns and nobody else can write" cyfr_root_owned
  check "candidate: /usr/local/bin/cyfr --version reports $INSTALL_VERSION" \
    sh -c 'sed 1d "$1" | grep -qF "$2"' sh "$GUEST_DIR/cyfr.txt" "$INSTALL_VERSION"

  pane_type '/usr/local/bin/cyfr --version; echo "version exit status $?"' &&
    pane_wait '^version exit status [0-9]+' 30
  check "candidate: screenshot s1-bootstrap.png" guest_screenshot s1-bootstrap.png

  step "candidate: does a reusable sudo login remain?"
  pane_type 'sudo -n true; echo "sudo -n status $?"' && pane_wait '^sudo -n status [0-9]+' 30
  probe=$(grep -oE '^sudo -n status [0-9]+' <<<"$PANE_SCREEN" | tail -n 1)
  echo "in the installer's terminal: ${probe:-no answer}" >"$GUEST_DIR/sudo-probe.txt"
  check "candidate: sudo -n true fails in the installer's terminal (${probe:-no answer})" probe_failed "$probe"
  status=0
  guest_ssh 'sudo -n true' >>"$GUEST_DIR/sudo-probe.txt" 2>&1 || status=$?
  echo "over SSH, without a terminal: status $status" >>"$GUEST_DIR/sudo-probe.txt"
  check "candidate: sudo -n true fails over SSH (status $status)" test "$status" != 0
  pane_save transcript.txt
  guest_packages packages-after.txt
  check "candidate: the only package change is cosign's installation" only_cosign_added
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict candidate
}

case_1() {
  local verdict=0 part
  for part in trunk candidate; do
    case $PART in "$part" | all) ;; *) continue ;; esac
    [ ! -e "$OUT/$part" ] || { echo "install-screen proof: $OUT/$part exists already" >&2; exit 64; }
  done
  if [ "$PART" = candidate ] && ! candidate_ready; then
    echo "candidate: not run: $ROOT/scripts/install.sh has no install policy block yet" | tee -a "$OUT/results.txt"
    return 77
  fi
  proof_image_build
  proof_kvm_preflight
  proof_base_verify
  proof_seed
  if [ "$PART" != candidate ]; then
    case_1_trunk || verdict=1
  fi
  if [ "$PART" != trunk ]; then
    if candidate_ready; then
      case_1_candidate || verdict=1
    else
      echo "candidate: not run: $ROOT/scripts/install.sh has no install policy block yet" | tee -a "$OUT/results.txt"
      [ "$verdict" != 0 ] || verdict=77
    fi
  fi
  return "$verdict"
}

# ---------------------------------------------------------------------------
# Cases 2 to 4: cyfr init on a machine without Docker, its retries and
# locks, and an earlier cyfr on PATH. Each boots one fresh guest. Cases 2
# and 3 run this tree's cyfr, built and placed root's at /usr/local/bin/cyfr
# by the harness (candidate_build): a stand-in for its signed delivery,
# which case 1 proves through the installer.
# ---------------------------------------------------------------------------

INIT_ANSWERS=('Install these requirements\? \(yes/no\)' yes "$SUDO_PROMPT" @password 'Choose 1, 2 or 3' 3)

transcript_has() { grep -qE -- "$2" "$GUEST_DIR/transcript-$1.txt"; }
transcript_lacks() { ! grep -qE -- "$2" "$GUEST_DIR/transcript-$1.txt"; }

# sudo -n true in the pane: the status it answers, after the step NAME.
pane_sudo_probe() {
  pane_step "$1" 'sudo -n true' 30 "$SUDO_PROMPT" @password
  echo "$1: sudo -n true exited $PANE_STATUS, ${PANE_ANSWERED[0]} password prompts" >>"$GUEST_DIR/sudo-probe.txt"
  pane_step_end "$1"
}

apt_transactions() { guest_ssh 'grep -c "^Start-Date:" /var/log/apt/history.log 2>/dev/null || echo 0'; }

case_2() {
  local before after
  guest_boot c2 8192 40G
  tty1_login
  guest_provision_candidate
  guest_ssh 'sudo --version 2>&1 | head -n 1; dpkg-query -W -f "\${Package} \${Version}\n" sudo-rs sudo 2>/dev/null' >"$GUEST_DIR/sudo-version.txt"
  check "c2: the guest's sudo is sudo-rs ($(head -n 1 "$GUEST_DIR/sudo-version.txt"))" grep -qi 'sudo-rs' "$GUEST_DIR/sudo-version.txt"
  check "c2: there is no Docker before init" guest_ssh '! command -v docker && ! dpkg-query -W -f "\${db:Status-Abbrev}" docker.io 2>/dev/null | grep -q "^ii"'

  step "c2: what sudo-rs's per-command -k leaves behind"
  : >"$GUEST_DIR/sudo-probe.txt"
  # No prior timestamp: a successful sudo -k, then a probe.
  pane_step c2-k-fresh 'sudo -k true' 60 "$SUDO_PROMPT" @password
  echo "c2-k-fresh: sudo -k true exited $PANE_STATUS after ${PANE_ANSWERED[0]} password prompts" >>"$GUEST_DIR/sudo-probe.txt"
  pane_step_end c2-k-fresh
  pane_sudo_probe c2-probe-fresh
  check "c2: with no prior timestamp, a successful sudo -k leaves no reusable login" grep -qE '^c2-probe-fresh: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  # A prior timestamp: sudo -v, then sudo -k, then a probe, then sudo -k alone.
  pane_step c2-v 'sudo -v' 60 "$SUDO_PROMPT" @password
  echo "c2-v: sudo -v exited $PANE_STATUS after ${PANE_ANSWERED[0]} password prompts" >>"$GUEST_DIR/sudo-probe.txt"
  pane_step_end c2-v
  pane_step c2-k-prior 'sudo -k true' 60 "$SUDO_PROMPT" @password
  echo "c2-k-prior: sudo -k true exited $PANE_STATUS after ${PANE_ANSWERED[0]} password prompts" >>"$GUEST_DIR/sudo-probe.txt"
  pane_step_end c2-k-prior
  pane_sudo_probe c2-probe-prior
  pane_step c2-invalidate 'sudo -k' 30 "$SUDO_PROMPT" @password
  pane_step_end c2-invalidate
  pane_sudo_probe c2-probe-invalidated
  check "c2: sudo -k alone invalidates a prior login" grep -qE '^c2-probe-invalidated: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  guest_ssh 'sudo -K' >/dev/null 2>&1 || true

  step "c2: cyfr init on a machine without Docker"
  before=$(apt_transactions)
  pane_step c2-init 'mkdir -p ~/cyfr && cd ~/cyfr && cyfr init' 2400 "${INIT_ANSWERS[@]}"
  check "c2: init exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c2: init asks \"Install these requirements?\" once" test "${PANE_ANSWERED[0]}" = 1
  check "c2: sudo asks the password once (asked ${PANE_ANSWERED[1]})" test "${PANE_ANSWERED[1]}" = 1
  check "c2: the preview shows the exact commands before the question" sh -c \
    'sed "/Install these requirements/q" "$1" | grep -qF "apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends docker.io docker-compose-v2" &&
     sed "/Install these requirements/q" "$1" | grep -qF "usermod -aG docker proof" &&
     sed "/Install these requirements/q" "$1" | grep -qF "systemctl enable --now docker.service" &&
     sed "/Install these requirements/q" "$1" | grep -qF "Members of the docker group control Docker"' sh "$GUEST_DIR/transcript-c2-init.txt"
  check "c2: init continued, asking how CYFR is reached after the install" transcript_has c2-init 'How will you reach CYFR\?'
  check "c2: init prepared the project" transcript_has c2-init '^CYFR project initialized\.'
  check "c2: init offers newgrp or a new login before cyfr up" transcript_has c2-init 'Run `newgrp docker` here, or log out and in again, before `cyfr up`\.'
  check "c2: init closes by naming cyfr up" transcript_has c2-init "Next: run 'cyfr up' to start the stack\."
  pane_step_end c2-init
  pane_sudo_probe c2-probe-after-init
  check "c2: no reusable sudo login is left after init" grep -qE '^c2-probe-after-init: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  guest_ssh 'sudo -n true' >/dev/null 2>&1
  check "c2: nor over SSH" test "$?" != 0

  pane_step c2-groups 'echo "groups: $(id -nG)"; docker info >/dev/null 2>&1; echo "docker info $?"' 30
  check "c2: the terminal init ran in keeps its old groups" sh -c 'grep -q "^groups: " "$1" && ! grep -qE "^groups: (.* )?docker( |$)" "$1" && grep -qE "^docker info [1-9]" "$1"' sh "$GUEST_DIR/transcript-c2-groups.txt"
  pane_step_end c2-groups
  guest_ssh_relogin
  guest_ssh 'getent group docker; stat -c "%U:%G %n" ~/cyfr ~/cyfr/.env ~/cyfr/docker-compose.yml ~/cyfr/data ~/cyfr/aqua; id' >"$GUEST_DIR/project.txt" 2>&1
  check "c2: the account is in the docker group" grep -qE '^docker:x:[0-9]+:(.*,)?proof(,.*)?$' "$GUEST_DIR/project.txt"
  check "c2: the project's files are the account's" sh -c '[ "$(grep -c "^proof:proof " "$1")" = 5 ]' sh "$GUEST_DIR/project.txt"

  step "c2: newgrp docker, then cyfr up"
  pane_type 'newgrp docker' || fail "newgrp was not typed"
  pane_wait '\$ *$' 30 || true
  pane_step c2-up 'cd ~/cyfr && cyfr up' 1800 "$SUDO_PROMPT" @password
  check "c2: cyfr up exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c2: cyfr up asks no password (asked ${PANE_ANSWERED[0]})" test "${PANE_ANSWERED[0]}" = 0
  guest_ssh 'docker version --format "server {{.Server.Version}}"; docker compose version --short | sed "s/^/compose /"
    docker info --format "cgroup {{.CgroupVersion}}"; docker info --format "{{json .SecurityOptions}}" | sed "s/^/security /"
    apt-cache policy docker.io docker-compose-v2 | sed "s/^/policy /"
    cd ~/cyfr && docker compose ps --format "{{.Service}} {{.State}} {{.Health}}"' >"$GUEST_DIR/docker.txt" 2>&1
  check "c2: Docker 28 or later" sh -c 'v=$(sed -n "s/^server \([0-9]*\)\..*/\1/p" "$1"); [ -n "$v" ] && [ "$v" -ge 28 ]' sh "$GUEST_DIR/docker.txt"
  check "c2: Compose v2 or later" sh -c 'v=$(sed -n "s/^compose v\{0,1\}\([0-9]*\)\..*/\1/p" "$1"); [ -n "$v" ] && [ "$v" -ge 2 ]' sh "$GUEST_DIR/docker.txt"
  check "c2: the daemon uses cgroup v2" grep -qx 'cgroup 2' "$GUEST_DIR/docker.txt"
  check "c2: the daemon applies AppArmor" grep -q '^security .*name=apparmor' "$GUEST_DIR/docker.txt"
  check "c2: Docker is Ubuntu's, from its archive" grep -qE '^policy +500 https?://[a-z.]*ubuntu\.com/ubuntu resolute(-updates|-security)?/universe' "$GUEST_DIR/docker.txt"
  check "c2: the stack's cyfr service runs" grep -qE '^cyfr running' "$GUEST_DIR/docker.txt"
  check "c2: screenshot s1-ready.png" guest_screenshot s1-ready.png
  pane_step_end c2-up

  step "c2: a second init changes nothing"
  guest_ssh 'cd ~/cyfr && sha256sum .env docker-compose.yml Caddyfile; docker ps -q --no-trunc | sort' >"$GUEST_DIR/before-second-init.txt" 2>&1
  before=$(apt_transactions)
  pane_step c2-init-again 'cd ~/cyfr && cyfr init --no-pull' 300 "${INIT_ANSWERS[@]}"
  after=$(apt_transactions)
  guest_ssh 'cd ~/cyfr && sha256sum .env docker-compose.yml Caddyfile; docker ps -q --no-trunc | sort' >"$GUEST_DIR/after-second-init.txt" 2>&1
  echo "apt transactions: $before before the second init, $after after" >>"$GUEST_DIR/results.txt"
  check "c2: the second init exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c2: the second init shows and asks nothing (asked ${PANE_ANSWERED[0]}, ${PANE_ANSWERED[1]} passwords)" test "${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}/${PANE_ANSWERED[2]}" = 0/0/0
  check "c2: the second init makes no apt transaction ($before, then $after)" test "$before" = "$after"
  check "c2: the second init rewrites nothing and starts or stops no container" cmp -s "$GUEST_DIR/before-second-init.txt" "$GUEST_DIR/after-second-init.txt"
  pane_step_end c2-init-again
  pane_sudo_probe c2-probe-end
  check "c2: no reusable sudo login at the end" grep -qE '^c2-probe-end: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict c2
}

# hold LOCK UNIT: root holds the lock LOCK (install, lists or dpkg) in the
# transient unit UNIT, as another installer, apt or dpkg would.
hold() {
  local holder
  case $1 in
    install) holder='/usr/bin/flock /run/cyfr-install.lock /usr/bin/sleep 600' ;;
    lists) holder="/usr/bin/python3 -c 'import fcntl,time; f=open(\"/var/lib/apt/lists/lock\",\"w\"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(600)'" ;;
    dpkg) holder="/usr/bin/python3 -c 'import fcntl,time; f=open(\"/var/lib/dpkg/lock-frontend\",\"w\"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(600)'" ;;
  esac
  guest_root "systemd-run --unit=$2 --quiet $holder && sleep 2 && systemctl is-active --quiet $2" || fail "the $1 lock was not taken"
}

case_3() {
  local lock unit sentence begin elapsed before after
  guest_boot c3 4096 30G
  tty1_login
  guest_provision_candidate
  guest_ssh 'mkdir -p ~/c3'
  guest_packages packages-before.txt

  step "c3: declined"
  pane_step c3-declined 'cd ~/c3 && cyfr init --no-pull' 120 'Install these requirements\? \(yes/no\)' no "$SUDO_PROMPT" @password
  check "c3: a declined install exits 1 and runs no sudo" test "$PANE_STATUS/${PANE_ANSWERED[1]}" = 1/0
  check "c3: it says what was not installed and that nothing was" transcript_has c3-declined '^(Error: )?You chose not to install docker\.io, docker-compose-v2, the running Docker service and proof.s membership of the docker group\. Nothing was installed\. Run `cyfr init` again when you want to continue\.'
  pane_step_end c3-declined

  for lock in install lists dpkg; do
    step "c3: the $lock lock, held"
    unit="cyfr-proof-hold-$lock"
    hold "$lock" "$unit"
    case $lock in
      install) sentence='^(Error: )?Another CYFR installation is still running after 60 seconds\. Nothing was installed\. Let it finish, then run `cyfr init` again\.'; PANE_MARKS=("$SUDO_PROMPT") ;;
      lists) sentence='^(Error: )?A package-list update is still running after 60 seconds\. Nothing was installed\. Let it finish, then run `cyfr init` again\.'; PANE_MARKS=('^→ apt-get update') ;;
      dpkg) sentence='^(Error: )?A package installation is still running after 60 seconds\. Nothing was installed\. Let it finish, then run `cyfr init` again\.'; PANE_MARKS=('^→ apt-get -o DPkg::Lock::Timeout=60 install') ;;
    esac
    pane_step "c3-$lock" 'cd ~/c3 && cyfr init --no-pull' 300 "${INIT_ANSWERS[@]}"
    PANE_MARKS=()
    begin=${PANE_MARK_AT[0]:-}
    elapsed=$(( PANE_DONE_AT - ${begin:-0} ))
    echo "c3-$lock: refused ${elapsed}s after the wait began (mark at ${begin:-never}, end at $PANE_DONE_AT)" >>"$GUEST_DIR/locks.txt"
    check "c3: the $lock lock refuses with its own sentence" transcript_has "c3-$lock" "$sentence"
    check "c3: the $lock lock refuses within its 60 s wait and 5 s more (${elapsed}s, read each second)" test -n "$begin" -a "$elapsed" -ge 58 -a "$elapsed" -le 67
    check "c3: the $lock lock's holder still runs, its lock untouched" guest_root "systemctl is-active --quiet $unit"
    pane_step_end "c3-$lock"
    guest_root "systemctl stop $unit" || true
  done
  guest_packages packages-after-locks.txt
  check "c3: nothing was installed while a lock was held" cmp -s "$GUEST_DIR/packages-before.txt" "$GUEST_DIR/packages-after-locks.txt"

  step "c3: offline"
  # Nothing leaves the guest's own network, QEMU's 10.0.2.0/24: the
  # archive is unreachable, SSH through QEMU's forward is not.
  printf '%s\n' 'table inet cyfr_proof_offline {' '  chain out {' \
    '    type filter hook output priority 0; policy accept;' '    oif "lo" accept' \
    '    ip daddr 10.0.2.0/24 accept' '    drop' '  }' '}' >"$WORK/offline.nft"
  guest_copy_in "$WORK/offline.nft" offline.nft || fail "the offline rules were not copied into the guest"
  guest_root "nft -f /home/$PROOF_USER/offline.nft" || fail "the guest was not taken offline ($GUEST_DIR/root.txt)"
  check "c3: offline, the archive is unreachable" guest_ssh '! timeout 10 curl -fsS -o /dev/null http://archive.ubuntu.com/ubuntu/'
  pane_step c3-offline 'cd ~/c3 && cyfr init --no-pull' 900 "${INIT_ANSWERS[@]}"
  guest_root 'nft delete table inet cyfr_proof_offline' || fail "the guest was not brought back online"
  check "c3: offline, init names the package step and the connection" transcript_has c3-offline '^(Error: )?CYFR could not (download Ubuntu.s package lists|finish installing docker\.io and docker-compose-v2)\. Nothing was installed\. Check the connection'
  pane_step_end c3-offline

  step "c3: interrupted while dpkg unpacks, then retried"
  PANE_MARKS=('^(Unpacking|Setting up) ')
  pane_type 'cd ~/c3 && cyfr init --no-pull; echo "c3-interrupt exit status $?"'
  pane_converse 900 '^(Unpacking|Setting up) ' 'Install these requirements\? \(yes/no\)' yes "$SUDO_PROMPT" @password ||
    fail "dpkg did not start unpacking within 900 s"
  PANE_MARKS=()
  guest_ssh 'tmux send-keys -t proof C-c'
  pane_converse 300 '^c3-interrupt exit status [0-9]+' || fail "the interrupted init did not end within 300 s"
  pane_save transcript-c3-interrupt.txt
  check "c3: the interrupted init exits 130" transcript_has c3-interrupt '^c3-interrupt exit status 130'
  check "c3: it names what the interrupt left, not nothing, and how to finish" transcript_has c3-interrupt '^(\^C)?(Error: )?Interrupted while installing .*\. CYFR (installed|left|finished|started|added) .*\. Run `cyfr init` again to finish'
  pane_step_end c3-interrupt
  guest_ssh 'dpkg --audit; dpkg-query -W -f "\${Package} \${db:Status-Abbrev}\n" docker.io docker-compose-v2 apparmor' >"$GUEST_DIR/after-interrupt.txt" 2>&1
  pane_step c3-retry 'cd ~/c3 && cyfr init --no-pull' 1200 "${INIT_ANSWERS[@]}"
  check "c3: the retry finishes and prepares the project (exit $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c3: the retry shows only what remains, and asks once" test "${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}" = 1/1
  guest_ssh 'getent group docker; dpkg --audit; dpkg-query -W -f "\${Package} \${db:Status-Abbrev}\n" docker.io docker-compose-v2 apparmor; systemctl is-active docker.service' >"$GUEST_DIR/after-retry.txt" 2>&1
  check "c3: the account is in the docker group once" grep -qE '^docker:x:[0-9]+:proof$' "$GUEST_DIR/after-retry.txt"
  check "c3: every package is installed and dpkg reports nothing unfinished" sh -c '[ "$(grep -c " ii $" "$1")" = 3 ] && grep -qx active "$1"' sh "$GUEST_DIR/after-retry.txt"
  check "c3: screenshot s1-retry.png" guest_screenshot s1-retry.png
  pane_step_end c3-retry

  step "c3: init again from the terminal that started before the group"
  before=$(apt_transactions)
  pane_step c3-refresh 'cd ~/c3 && cyfr init --no-pull' 120 "${INIT_ANSWERS[@]}"
  after=$(apt_transactions)
  check "c3: it asks for newgrp or a new login, runs no sudo and no apt" test "$PANE_STATUS/${PANE_ANSWERED[1]}/$before" = "1/0/$after"
  check "c3: the refresh sentence" transcript_has c3-refresh 'Run `newgrp docker`, or log out and in again, then run `cyfr init` again\.'
  pane_step_end c3-refresh
  pane_sudo_probe c3-probe-end
  check "c3: no reusable sudo login at the end" grep -qE '^c3-probe-end: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict c3
}

case_4() {
  local line
  cp "$ROOT/scripts/install.sh" "$WORK/install-candidate.sh" || fail "the candidate script was not copied"
  guest_boot c4 2048 20G
  tty1_login
  guest_copy_in "$WORK/install-candidate.sh" install.sh || fail "the candidate script was not copied into the guest"
  echo "sha256: $(sha256sum <"$WORK/install-candidate.sh" | cut -d ' ' -f 1)" >"$GUEST_DIR/installer.txt"

  step "c4: an earlier cyfr in ~/.local/bin, ahead of /usr/local/bin"
  pane_step c4-local "mkdir -p ~/.local/bin && cat install.sh | CYFR_VERSION=$INSTALL_VERSION CYFR_INSTALL_DIR=\$HOME/.local/bin sh" 900 \
    'Install these requirements\? \[y/N\]' y "$SUDO_PROMPT" @password
  check "c4: the installer puts the earlier copy in ~/.local/bin (exit $PANE_STATUS)" test "$PANE_STATUS" = 0
  pane_step_end c4-local
  pane_step c4-path 'export PATH="$HOME/.local/bin:$PATH"; hash -r; command -v cyfr' 30
  check "c4: typing cyfr runs ~/.local/bin/cyfr" transcript_has c4-path '^/home/proof/\.local/bin/cyfr$'
  pane_step_end c4-path

  step "c4: the default install, migration declined"
  pane_step c4-decline "cat install.sh | CYFR_VERSION=$INSTALL_VERSION sh" 900 \
    'Install these requirements\? \[y/N\]' y "$SUDO_PROMPT" @password 'Remove the earlier copy\? \[y/N\]' n
  check "c4: the install to /usr/local/bin succeeds (exit $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c4: it names both copies before asking" transcript_has c4-decline '^Typing `cyfr` runs /home/proof/\.local/bin/cyfr; the new version is at /usr/local/bin/cyfr\. Remove the earlier copy\? \[y/N\]'
  check "c4: declined, it says the earlier copy still runs and gives the new path" transcript_has c4-decline 'Typing `cyfr` still runs /home/proof/\.local/bin/cyfr\. Run the new version as /usr/local/bin/cyfr, for example `/usr/local/bin/cyfr init`\.'
  pane_step_end c4-decline
  pane_step c4-after-decline 'hash -r; command -v cyfr; ls -l ~/.local/bin/cyfr /usr/local/bin/cyfr' 30
  check "c4: declined, the earlier copy stays and still runs" transcript_has c4-after-decline '^/home/proof/\.local/bin/cyfr$'
  pane_step_end c4-after-decline

  step "c4: the default install again, migration accepted"
  pane_step c4-accept "cat install.sh | CYFR_VERSION=$INSTALL_VERSION sh" 900 \
    'Install these requirements\? \[y/N\]' y "$SUDO_PROMPT" @password 'Remove the earlier copy\? \[y/N\]' y
  check "c4: the rerun succeeds (exit $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c4: a rerun of the installed version elevates nothing (${PANE_ANSWERED[1]} passwords)" test "${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}" = 0/0
  check "c4: accepted, it tells the shell to forget the old path" transcript_has c4-accept 'Run `hash -r`, or open a new terminal, so that typing `cyfr` runs /usr/local/bin/cyfr\.'
  pane_step c4-after-accept 'hash -r; command -v cyfr; cyfr --version; test ! -e ~/.local/bin/cyfr && echo "earlier copy removed"' 30
  check "c4: typing cyfr now runs /usr/local/bin/cyfr, the installed version" sh -c 'grep -qx /usr/local/bin/cyfr "$1" && grep -qF "$2" "$1" && grep -qx "earlier copy removed" "$1"' sh "$GUEST_DIR/transcript-c4-after-accept.txt" "$INSTALL_VERSION"
  check "c4: screenshot s1-path.png" guest_screenshot s1-path.png
  pane_step_end c4-after-accept
  pane_sudo_probe c4-probe-end
  check "c4: no reusable sudo login at the end" grep -qE '^c4-probe-end: sudo -n true exited [1-9]' "$GUEST_DIR/sudo-probe.txt"
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict c4
}

case_n() {
  [ ! -e "$OUT/c$CASE" ] || { echo "install-screen proof: $OUT/c$CASE exists already" >&2; exit 64; }
  command -v go >/dev/null 2>&1 || [ "$CASE" = 4 ] || { echo "install-screen proof: go is required to build the candidate" >&2; exit 69; }
  proof_image_build
  proof_kvm_preflight
  proof_base_verify
  proof_seed
  "case_$CASE"
}

status=0
case $CASE in
  1) case_1 || status=$? ;;
  *) case_n || status=$? ;;
esac
echo
echo "install-screen proof: case $CASE: $(tr '\n' ';' <"$OUT/results.txt" 2>/dev/null) evidence in $OUT"
exit "$status"

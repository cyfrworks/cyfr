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
#   trunk      scripts/install.sh at TRUNK_COMMIT, the trunk before
#              this change, cosign absent: it refuses, cosign being
#              required, asks no password and changes no package
#              (s1-trunk.png).
#   candidate  this tree's scripts/install.sh, copied as the part starts:
#              it previews, asks "Install these requirements?" (answered
#              y), asks the sudo password once, installs cosign from
#              Ubuntu and nothing else, verifies the release's signature
#              and checksum and installs a root-owned /usr/local/bin/cyfr
#              that reports 0.6.0-alpha.5 (s1-bootstrap.png). Afterwards
#              `sudo -n true` meets sudo's own refusal, in that terminal
#              and over SSH. A script without an `install policy` block is
#              not run.
#   all        (default) trunk, then candidate, each in its own guest.
# Case 2, cyfr init on a machine without Docker: what sudo-rs's
# per-command -k leaves, with and without a prior login; init's preview,
# one question and one password, the init continued through sg docker,
# newgrp before cyfr
# up, Docker 28+ and Compose v2 installed from Ubuntu's archive, cgroup v2
# and AppArmor, the account's project files, no reusable sudo login after
# it, and a second init that shows nothing and makes no apt transaction
# (s1-ready.png). Case 3, its refusals and retries: declined, each of the
# three locks held, offline, then an interrupt at each durable action,
# each retried: during apt-get update, during dpkg's unpack, while
# systemctl enables and starts docker.service, and while usermod adds the
# account to the docker group, each interrupted run saying what it left,
# and a last retry that converges; then the terminal that predates the
# group (s1-retry.png). Case 4, an earlier cyfr in ~/.local/bin: the
# installer's migration declined, then accepted (s1-path.png). Cases 2
# and 3 run a stand-in for the candidate's delivery, which their results
# say (lib.sh, candidate_build).
#
# Evidence goes under DIR (default a fresh
# /tmp/cyfr-evidence.install-screen-case<N>.XXXXXX, printed, which
# scripts/janitor.sh removes a week later, its rule 5), which keeps it:
# the KVM preflight and the base image's verification, then one directory
# per part, which must not exist yet, holding
# results.txt, kvm.txt (QEMU's KVM state, version, descriptors and command
# line), guest.txt, cloud-init.txt, the package lists before and after,
# the installer's provenance and typed line (installer.txt), the terminal's
# transcript, the serial console, QEMU's log, the journal, apt's history
# and the named screenshots. DIR/results.txt holds one verdict per part.
# Only disks are on disk: the base image is the host's cache, which
# tests/install-screen-proof/prepare.sh fills and verifies outside any
# lane and the run mounts read-only and verifies again with no network,
# and each guest's overlay is in the Docker volume ${PROOF_RUN_PREFIX}disk.
# The containers run the proof image prepare.sh builds outside any lane,
# shared by every worktree at the same inputs, which the run records its
# use of and neither builds nor removes. Without either the run exits 69,
# naming prepare.sh. Each case ends itself within 3420 s, inside the proof
# rows' 3600 s hold with the teardown's margin (lib.sh, CASE_SECONDS).
#
# Every name the run gives Docker begins with PROOF_RUN_PREFIX, which
# scripts/heavy-check.sh sets; unset, it is scripts/lib/run-names.sh's
# prefix with this script's pid, and set to anything but such a prefix it
# is refused. The run makes the volume and the containers
# ${PROOF_RUN_PREFIX}kvm, ...verify and ...qemu-<part>, and removes them on
# every exit (cleanup.sh). It is a proof-lane check:
#   scripts/heavy-check.sh -p -t 3600 -- tests/install-screen-proof/run.sh --case 1
#
# Needs docker with the host's /dev/kvm, ssh, ssh-keygen, git, python3,
# timeout, flock, the base image's cache and the proof image, go for
# cases 2 and 3, and the guests' network: Ubuntu's archive and GitHub's
# releases.
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
# Case 1's trunk: the commit before this change, whose installer requires
# cosign and installs nothing itself.
TRUNK_COMMIT=6ac2382cc9981aa069d1aa337646b0c25d398797

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
VOLUME="${PROOF_PREFIX}disk"

for tool in docker ssh ssh-keygen git python3 timeout flock; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install-screen proof: $tool is required" >&2; exit 69; }
done
[ -c /dev/kvm ] || { echo "install-screen proof: this host has no /dev/kvm" >&2; exit 69; }
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo "install-screen proof: no Docker daemon answers" >&2; exit 69; }

if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "/tmp/cyfr-evidence.install-screen-case$CASE.XXXXXX") || exit 1
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
  git -C "$ROOT" cat-file -e "$TRUNK_COMMIT^{commit}" 2>/dev/null ||
    fail "the trunk commit $TRUNK_COMMIT is not in this repository; fetch it (git fetch origin main)"
  git -C "$ROOT" show "$TRUNK_COMMIT:scripts/install.sh" >"$WORK/install-trunk.sh" ||
    fail "$TRUNK_COMMIT has no scripts/install.sh"
  guest_boot trunk 2048 20G
  tty1_login
  guest_packages packages-before.txt
  check "trunk: cosign is not installed before the run" guest_cosign_absent
  {
    echo "script: scripts/install.sh at $TRUNK_COMMIT, the trunk before this change"
    echo "sha256: $(sha256sum <"$WORK/install-trunk.sh" | cut -d ' ' -f 1)"
    echo "typed: $(install_line install.sh)"
  } >"$GUEST_DIR/installer.txt"
  guest_copy_in "$WORK/install-trunk.sh" install.sh || fail "the trunk script was not copied into the guest"

  step "trunk: the installer, typed into tty1's terminal"
  pane_type "$(install_line install.sh)" || fail "the installer's line was not typed"
  if ! pane_converse 600 '^installer exit status [0-9]+' "$SUDO_PROMPT" @password; then
    pane_save transcript.txt
    guest_screenshot s1-trunk.png || true
    fail "trunk: the installer did not finish within $PANE_BUDGET s ($GUEST_DIR/transcript.txt)"
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
  grep -q '^ii ' "$GUEST_DIR/cosign.txt" && apt_installed_from_archive "$GUEST_DIR/cosign.txt" cosign '' '[a-z]+'
}

# Whether the only package change is cosign's installation.
only_cosign_added() {
  diff "$GUEST_DIR/packages-before.txt" "$GUEST_DIR/packages-after.txt" >"$GUEST_DIR/packages-changed.txt"
  [ "$(grep -c '^[<>]' "$GUEST_DIR/packages-changed.txt")" = 1 ] &&
    grep -qE $'^> cosign\t[^\t]+\tii $' "$GUEST_DIR/packages-changed.txt"
}

cyfr_root_owned() {
  local owner mode kind
  read -r owner mode kind <<<"$(sed -n 1p "$GUEST_DIR/cyfr.txt")"
  [ "$owner" = root:root ] && [ "$kind" = "regular file" ] && [[ $mode =~ ^[0-7]{3,4}$ ]] &&
    [ $((8#$mode & 8#022)) = 0 ]
}

case_1_candidate() {
  local status prompts
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
    fail "candidate: the installer did not finish within $PANE_BUDGET s, or asked a question a fourth time ($GUEST_DIR/transcript.txt)"
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
  pane_save transcript.txt

  step "candidate: does a reusable sudo login remain?"
  pane_type 'clear' && guest_ssh 'tmux clear-history -t proof' && pane_wait '\$ *$' 30 ||
    fail "candidate: the installer's terminal was not cleared for the probe"
  : >"$GUEST_DIR/sudo-probe.txt"
  pane_sudo_probe candidate-probe
  check "candidate: sudo -n true in the installer's terminal is sudo's refusal (exit 1, no prompt, $SUDO_REFUSAL)" \
    probe_refused candidate-probe
  check "candidate: and over SSH, without a terminal" ssh_sudo_refused candidate-ssh-probe
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
  proof_image_use
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
# which case 1 proves through the installer, and which their results.txt
# and candidate.txt say.
# ---------------------------------------------------------------------------

INIT_ANSWERS=('Install these requirements\? \(yes/no\)' yes "$SUDO_PROMPT" @password 'Choose 1, 2 or 3' 3)

transcript_has() { grep -qE -- "$2" "$GUEST_DIR/transcript-$1.txt"; }
transcript_lacks() { ! grep -qE -- "$2" "$GUEST_DIR/transcript-$1.txt"; }

apt_transactions() { guest_ssh 'grep -c "^Start-Date:" /var/log/apt/history.log 2>/dev/null || echo 0'; }

# Case 2's budgets, in seconds, inside the case's 3420 (CASE_SECONDS):
# cyfr init 1200 and cyfr up 900, the two steps that download, and the
# second init 180, 2280 together; the 1140 left cover the preflight (at
# most 120), the base's verification (at most 300, about 10), the
# candidate's build (at most 300, about 30), the boot (at most 600, about
# 60) and the sign-in, the sudo-rs probes and the checks between them
# (about 300 together). Every wait is cut at the case's deadline as well
# (budget), so a step that overruns its own budget cannot outlast the
# hold.
case_2() {
  local before after
  guest_boot c2 8192 40G
  tty1_login
  guest_provision_candidate
  guest_ssh 'sudo --version 2>&1 | head -n 1; dpkg-query -W -f "\${Package} \${Version}\n" sudo-rs sudo 2>/dev/null' >"$GUEST_DIR/sudo-version.txt"
  check "c2: the guest's sudo is sudo-rs ($(head -n 1 "$GUEST_DIR/sudo-version.txt"))" grep -qi 'sudo-rs' "$GUEST_DIR/sudo-version.txt"
  check "c2: there is no Docker before init" guest_ssh '! command -v docker && ! dpkg-query -W -f "\${db:Status-Abbrev}" docker.io 2>/dev/null | grep -q "^ii"'

  # Each step's premise is checked as well as its outcome, so none passes
  # with nothing to observe: a refusal is sudo's own, with its words; a
  # step that should log in did, after the prompts it should show.
  step "c2: what sudo-rs's per-command -k leaves behind"
  : >"$GUEST_DIR/sudo-probe.txt"
  pane_sudo_probe c2-probe-start
  check "c2: the terminal starts with no sudo login, the harness's own root calls having given it none (sudo's refusal)" \
    probe_refused c2-probe-start
  # No prior login: a successful sudo -k, then a probe.
  pane_sudo_step c2-k-fresh 'sudo -k true'
  check "c2: sudo -k true, with no prior login, exits 0 after exactly one password prompt" sudo_step_was c2-k-fresh 0 1
  pane_sudo_probe c2-probe-fresh
  check "c2: with no prior login, a successful sudo -k leaves no reusable login (sudo's refusal)" probe_refused c2-probe-fresh
  # A prior login: sudo -v, then sudo -k, then a probe, then sudo -k alone.
  pane_sudo_step c2-v 'sudo -v'
  check "c2: sudo -v exits 0 after one password prompt" sudo_step_was c2-v 0 1
  pane_sudo_step c2-k-prior 'sudo -k true'
  check "c2: sudo -k true, with a prior login, exits 0 ($(sed -n 's/^c2-k-prior: //p' "$GUEST_DIR/sudo-probe.txt"))" \
    grep -qE '^c2-k-prior: .* exited 0 after ' "$GUEST_DIR/sudo-probe.txt"
  pane_sudo_probe c2-probe-prior
  check "c2: with a prior login, sudo -k true leaves that login (the probe exits 0 without a prompt)" probe_allowed c2-probe-prior
  pane_sudo_step c2-invalidate 'sudo -k'
  check "c2: sudo -k alone exits 0 without a prompt" sudo_step_was c2-invalidate 0 0
  pane_sudo_probe c2-probe-invalidated
  check "c2: sudo -k alone invalidates a prior login (sudo's refusal), so init starts with none" probe_refused c2-probe-invalidated

  step "c2: cyfr init on a machine without Docker"
  pane_step c2-init 'mkdir -p ~/cyfr && cd ~/cyfr && cyfr init' 1200 "${INIT_ANSWERS[@]}"
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
  check "c2: no reusable sudo login is left after init (sudo's refusal)" probe_refused c2-probe-after-init
  check "c2: nor over SSH (sudo's refusal)" ssh_sudo_refused c2-ssh-probe-after-init

  pane_step c2-groups 'echo "groups: $(id -nG)"; docker info >/dev/null 2>&1; echo "docker info $?"' 30
  check "c2: the terminal init ran in keeps its old groups" sh -c 'grep -q "^groups: " "$1" && ! grep -qE "^groups: (.* )?docker( |$)" "$1" && grep -qE "^docker info [1-9]" "$1"' sh "$GUEST_DIR/transcript-c2-groups.txt"
  pane_step_end c2-groups
  guest_ssh_relogin
  guest_ssh 'getent group docker; stat -c "%U:%G %n" ~/cyfr ~/cyfr/.env ~/cyfr/docker-compose.yml ~/cyfr/data ~/cyfr/aqua; id' >"$GUEST_DIR/project.txt" 2>&1
  check "c2: the account is in the docker group" grep -qE '^docker:x:[0-9]+:(.*,)?proof(,.*)?$' "$GUEST_DIR/project.txt"
  # The init that continues through sg docker has docker for its group, so
  # what it makes is the account's, in the docker group.
  check "c2: the project's files are the account's" sh -c '[ "$(grep -cE "^proof:(proof|docker) " "$1")" = 5 ]' sh "$GUEST_DIR/project.txt"

  step "c2: newgrp docker, then cyfr up"
  pane_type 'newgrp docker' || fail "newgrp was not typed"
  pane_wait '\$ *$' 30 || true
  pane_step c2-up 'cd ~/cyfr && cyfr up' 900 "$SUDO_PROMPT" @password
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
  check "c2: the installed docker.io is Ubuntu's, from resolute's universe (its *** version's sources)" \
    apt_installed_from_archive "$GUEST_DIR/docker.txt" docker.io 'policy ' universe
  check "c2: the installed docker-compose-v2 is Ubuntu's, from resolute's universe (its *** version's sources)" \
    apt_installed_from_archive "$GUEST_DIR/docker.txt" docker-compose-v2 'policy ' universe
  check "c2: the stack's cyfr service runs" grep -qE '^cyfr running' "$GUEST_DIR/docker.txt"
  check "c2: screenshot s1-ready.png" guest_screenshot s1-ready.png
  pane_step_end c2-up

  step "c2: a second init changes nothing"
  guest_ssh 'cd ~/cyfr && sha256sum .env docker-compose.yml Caddyfile; docker ps -q --no-trunc | sort' >"$GUEST_DIR/before-second-init.txt" 2>&1
  before=$(apt_transactions)
  pane_step c2-init-again 'cd ~/cyfr && cyfr init --no-pull' 180 "${INIT_ANSWERS[@]}"
  after=$(apt_transactions)
  guest_ssh 'cd ~/cyfr && sha256sum .env docker-compose.yml Caddyfile; docker ps -q --no-trunc | sort' >"$GUEST_DIR/after-second-init.txt" 2>&1
  echo "apt transactions: $before before the second init, $after after" >>"$GUEST_DIR/results.txt"
  check "c2: the second init exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c2: the second init shows and asks nothing (asked ${PANE_ANSWERED[0]}, ${PANE_ANSWERED[1]} passwords)" test "${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}/${PANE_ANSWERED[2]}" = 0/0/0
  check "c2: the second init makes no apt transaction ($before, then $after)" test "$before" = "$after"
  check "c2: the second init rewrites nothing and starts or stops no container" cmp -s "$GUEST_DIR/before-second-init.txt" "$GUEST_DIR/after-second-init.txt"
  pane_step_end c2-init-again
  pane_sudo_probe c2-probe-end
  check "c2: no reusable sudo login at the end (sudo's refusal)" probe_refused c2-probe-end
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict c2
}

# hold LOCK UNIT: root holds the lock LOCK in the transient unit UNIT, as
# another holder would: install (CYFR's own), lists (apt's package
# lists), dpkg (dpkg's front end), or pwd (/etc/.pwd.lock, which usermod
# waits for through lckpwdf(3), up to 15 s, before it changes a group).
hold() {
  local holder
  case $1 in
    install) holder='/usr/bin/flock /run/cyfr-install.lock /usr/bin/sleep 600' ;;
    lists) holder="/usr/bin/python3 -c 'import fcntl,time; f=open(\"/var/lib/apt/lists/lock\",\"w\"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(600)'" ;;
    dpkg) holder="/usr/bin/python3 -c 'import fcntl,time; f=open(\"/var/lib/dpkg/lock-frontend\",\"w\"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(600)'" ;;
    pwd) holder="/usr/bin/python3 -c 'import fcntl,time; f=open(\"/etc/.pwd.lock\",\"a\"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(600)'" ;;
  esac
  guest_root "systemd-run --unit=$2 --quiet $holder && sleep 2 && systemctl is-active --quiet $2" || fail "the $1 lock was not taken"
}

# The machine's state an interrupted install can change, in GUEST_DIR/$1:
# every package dpkg knows with its version and state, the docker group,
# the Docker service's state, and what dpkg --audit reports.
guest_state() {
  guest_ssh 'dpkg-query -W -f "\${binary:Package}\t\${Version}\t\${db:Status-Abbrev}\n" | sort
    echo "group: $(getent group docker)"
    echo "service: $(systemctl is-active docker.service) $(systemctl is-enabled docker.service 2>/dev/null)"
    echo "audit:"; dpkg --audit' >"$GUEST_DIR/$1" 2>&1
}

# Run inside the guest as `sh interrupt-when.sh PATTERN SECONDS`: as soon
# as a process whose command line matches the extended regex PATTERN
# runs, within SECONDS, it types Ctrl-C into the pane and names the
# process; past SECONDS it types Ctrl-C all the same, saying that nothing
# matched, so the run still ends. It polls ten times a second.
INTERRUPT_WHEN='pattern=$1 n=0
while [ "$n" -lt "$(($2 * 10))" ]; do
  line=$(pgrep -a -f -- "$pattern" | head -n 1)
  if [ -n "$line" ]; then
    tmux send-keys -t proof C-c
    echo "interrupted while: $line"
    ps -eo pid,ppid,pgid,stat,etimes,args
    exit 0
  fi
  sleep 0.1
  n=$((n + 1))
done
tmux send-keys -t proof C-c
echo "interrupted late: no process matched $pattern within $2 s"
ps -eo pid,ppid,pgid,stat,etimes,args
exit 1'

# c3_interrupted NAME MARK PATTERN SECONDS LATER: `cyfr init --no-pull`
# typed into the pane and agreed as INIT_ANSWERS agree it until the pane
# shows a line matching MARK, the action's `→ <command>` line, which the
# parent prints as the action starts; then Ctrl-C, typed from inside the
# guest within 0.1 s of a process matching PATTERN running, waited for up
# to SECONDS (INTERRUPT_WHEN); then the run's end. LATER matches the line
# of the action after it, which a run interrupted in time never shows.
# Its evidence: transcript-NAME.txt, interrupt-NAME.txt and the machine's
# state before and after the run (state-before-NAME.txt,
# state-after-NAME.txt).
c3_interrupted() {
  local name=$1 mark=$2 pattern=$3 seconds=$4 later=$5 asked
  step "c3: $name, interrupted while $pattern runs"
  guest_state "state-before-$name.txt"
  pane_type "cd ~/c3 && cyfr init --no-pull; echo \"$name exit status \$?\"" || fail "$name: the line was not typed"
  if ! pane_converse 900 "$mark" "${INIT_ANSWERS[@]}"; then
    pane_save "transcript-$name.txt"
    guest_screenshot "$name-stuck.png" || true
    fail "$name: no line matching $mark within $PANE_BUDGET s ($GUEST_DIR/transcript-$name.txt)"
  fi
  asked="${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}"
  GUEST_SSH_TIMEOUT=$((seconds + 30)) guest_ssh "sh interrupt-when.sh $(printf '%q' "$pattern") $seconds" \
    >"$GUEST_DIR/interrupt-$name.txt" 2>&1
  if ! pane_converse 300 "^$name exit status [0-9]+"; then
    pane_save "transcript-$name.txt"
    guest_screenshot "$name-stuck.png" || true
    fail "$name: the interrupted init did not end within $PANE_BUDGET s ($GUEST_DIR/transcript-$name.txt)"
  fi
  pane_save "transcript-$name.txt"
  guest_state "state-after-$name.txt"
  check "c3: $name: init asked once and sudo asked once before the interrupt (asked $asked)" test "$asked" = 1/1
  check "c3: $name: the interrupt landed while $pattern ran ($(head -n 1 "$GUEST_DIR/interrupt-$name.txt"))" \
    grep -q '^interrupted while: ' "$GUEST_DIR/interrupt-$name.txt"
  check "c3: $name: the interrupted init exits 130" transcript_has "$name" "^$name exit status 130$"
  check "c3: $name: no later action started" transcript_lacks "$name" "$later"
  echo "$name: $(interrupt_sentence "$name")" >>"$GUEST_DIR/interrupts.txt"
  check "c3: $name: its sentence says what the interrupt left, and to run cyfr init again ($(interrupt_sentence "$name"))" \
    interrupt_sentence_true "$name"
  pane_step_end "$name"
  pane_sudo_probe "$name-probe"
  check "c3: $name: no reusable sudo login after the interrupt (sudo's refusal)" probe_refused "$name-probe"
}

# While the interrupts at the update, the unpack and the service's start
# run, maintainer scripts start no service (/usr/sbin/policy-rc.d exits
# 101, as Debian's policy defines it) and docker.service's start waits
# 60 s first (a drop-in's ExecStartPre): so `systemctl enable --now
# docker.service`, not a package's postinst, is what starts it, and it
# runs long enough for the interrupt to land in it. Both are removed once
# that interrupt has landed, before the runs that follow.
SLOW_START_ON='printf "#!/bin/sh\nexit 101\n" >/usr/sbin/policy-rc.d && chmod 0755 /usr/sbin/policy-rc.d &&
  mkdir -p /etc/systemd/system/docker.service.d &&
  printf "[Service]\nExecStartPre=/usr/bin/sleep 60\nTimeoutStartSec=300\n" >/etc/systemd/system/docker.service.d/cyfr-proof-slow-start.conf &&
  systemctl daemon-reload'
SLOW_START_OFF='rm -f /usr/sbin/policy-rc.d /etc/systemd/system/docker.service.d/cyfr-proof-slow-start.conf &&
  rmdir --ignore-fail-on-non-empty /etc/systemd/system/docker.service.d && systemctl daemon-reload'

case_3() {
  local lock unit sentence begin elapsed before after closes
  guest_boot c3 4096 30G
  tty1_login
  guest_provision_candidate
  guest_ssh 'mkdir -p ~/c3'
  printf '%s\n' "$INTERRUPT_WHEN" >"$WORK/interrupt-when.sh"
  guest_copy_in "$WORK/interrupt-when.sh" interrupt-when.sh || fail "the interrupter was not copied into the guest"
  guest_packages packages-before.txt

  # The probes read what the product leaves, since the harness's root
  # calls (guest_root) neither give tty1's terminal a sudo login nor take
  # one away; checked here before anything else, against a login of the
  # terminal's own.
  step "c3: the probes' premise"
  : >"$GUEST_DIR/sudo-probe.txt"
  pane_sudo_probe c3-probe-start
  check "c3: the terminal has no sudo login after the harness's own root calls (sudo's refusal)" probe_refused c3-probe-start
  pane_sudo_step c3-v 'sudo -v'
  check "c3: sudo -v in the terminal exits 0 after one password prompt" sudo_step_was c3-v 0 1
  guest_root true || fail "the harness's root call failed ($GUEST_DIR/root.txt)"
  pane_sudo_probe c3-probe-login
  check "c3: a harness root call leaves the terminal's login as it was, and a probe sees it (exit 0, no prompt)" \
    probe_allowed c3-probe-login
  pane_sudo_step c3-k 'sudo -k'
  pane_sudo_probe c3-probe-cleared
  check "c3: sudo -k ends that login before the product runs (sudo's refusal)" probe_refused c3-probe-cleared

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
    elapsed=$((PANE_DONE_AT - ${begin:-0}))
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

  # An interrupt at each durable action, in the order init takes them, so
  # each retry is the next one's run: the package lists' update (the
  # lists removed first, so it downloads them whole and runs for long
  # enough), dpkg's unpack, the service's start (SLOW_START_ON) and the
  # group change (with /etc/.pwd.lock held, so usermod waits for it); then
  # a last retry, which converges.
  step "c3: an interrupt at each durable action, each retried"
  guest_root "$SLOW_START_ON" || fail "the service's slow start was not set up ($GUEST_DIR/root.txt)"
  guest_root 'find /var/lib/apt/lists -maxdepth 1 -type f ! -name lock -delete' || fail "the package lists were not removed"
  c3_interrupted c3-update '^→ apt-get update' '^/usr/bin/apt-get update$' 60 '^→ apt-get -o '
  c3_interrupted c3-unpack '^→ apt-get -o DPkg::Lock::Timeout=60 install' '^/usr/bin/dpkg .*--unpack' 600 '^→ systemctl '
  check "c3: c3-unpack: dpkg's packages changed, so its sentence cannot say that nothing was installed" \
    packages_changed c3-unpack
  c3_interrupted c3-enable '^→ systemctl enable --now docker\.service' '^/usr/bin/systemctl enable --now docker\.service$' 30 '^→ usermod '
  check "c3: c3-enable: the retry repaired the interrupted package installation first exactly when dpkg --audit reported one" \
    repair_shown_iff_audit c3-enable
  guest_root "$SLOW_START_OFF" || fail "the service's slow start was not removed ($GUEST_DIR/root.txt)"
  # The start the interrupt left runs on in systemd; the next run is the
  # group change's alone once it has.
  closes=$((SECONDS + 180))
  until guest_ssh 'systemctl is-active --quiet docker.service'; do
    [ "$SECONDS" -lt "$closes" ] || fail "docker.service was not active within 180 s of the interrupted start"
    sleep 2
  done
  hold pwd cyfr-proof-hold-pwd
  c3_interrupted c3-group '^→ usermod -aG docker proof' '^/usr/sbin/usermod -aG docker proof$' 10 'How will you reach CYFR\?|started before proof joined'
  guest_root 'systemctl stop cyfr-proof-hold-pwd' || true
  check "c3: c3-group: the retry shows only what remained, the group change" test "$(preview_commands c3-group)" = 'usermod -aG docker proof'

  step "c3: the last retry converges"
  pane_step c3-retry 'cd ~/c3 && cyfr init --no-pull' 1200 "${INIT_ANSWERS[@]}"
  check "c3: the last retry finishes and prepares the project (exit $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "c3: the last retry asks once, and sudo once" test "${PANE_ANSWERED[0]}/${PANE_ANSWERED[1]}" = 1/1
  check "c3: the last retry shows only what remained, the group change" test "$(preview_commands c3-retry)" = 'usermod -aG docker proof'
  guest_ssh 'getent group docker; dpkg-query -W -f "\${Package} \${db:Status-Abbrev}\n" docker.io docker-compose-v2 apparmor
    echo "service: $(systemctl is-active docker.service) $(systemctl is-enabled docker.service)"
    echo "audit:"; dpkg --audit' >"$GUEST_DIR/after-retry.txt" 2>&1
  check "c3: the account is in the docker group exactly once" grep -qE '^docker:x:[0-9]+:proof$' "$GUEST_DIR/after-retry.txt"
  check "c3: every package is installed" sh -c '[ "$(grep -cE "^(docker\.io|docker-compose-v2|apparmor) ii $" "$1")" = 3 ]' sh "$GUEST_DIR/after-retry.txt"
  check "c3: dpkg --audit reports nothing unfinished" sh -c '[ -z "$(sed -n "/^audit:\$/,\$p" "$1" | sed 1d)" ]' sh "$GUEST_DIR/after-retry.txt"
  check "c3: the Docker service is active and enabled" grep -qx 'service: active enabled' "$GUEST_DIR/after-retry.txt"
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
  check "c3: no reusable sudo login at the end (sudo's refusal)" probe_refused c3-probe-end
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
  check "c4: no reusable sudo login at the end (sudo's refusal)" probe_refused c4-probe-end
  guest_journal
  proof_guest_stop "$GUEST" "$GUEST_DIR"
  part_verdict c4
}

case_n() {
  [ ! -e "$OUT/c$CASE" ] || { echo "install-screen proof: $OUT/c$CASE exists already" >&2; exit 64; }
  command -v go >/dev/null 2>&1 || [ "$CASE" = 4 ] || { echo "install-screen proof: go is required to build the candidate" >&2; exit 69; }
  proof_image_use
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

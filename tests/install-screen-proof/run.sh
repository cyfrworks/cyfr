#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install proof: a clean Ubuntu 26.04 guest under QEMU/KVM, the QEMU
# inside a container built from this directory's Dockerfile, so the
# verification host installs nothing and joins no group. A person's terminal
# on the guest's own screen runs the install script as `curl ... | sh` pipes
# it, with production trust, then `cyfr init` and `cyfr up`, and CYFR answers
# on its port:
#
#   tests/install-screen-proof/run.sh [--out DIR]
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

usage() { echo "usage: $0 [--out DIR]"; }
OUT=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --out)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      OUT=$2
      shift 2
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
  pane_step_end script

  step "cyfr init on a machine without Docker"
  guest_copy_in "$CANDIDATE_BIN" .local/bin/cyfr || fail "the candidate was not copied into the guest"
  pane_step init 'export PATH="$HOME/.local/bin:$PATH"; mkdir -p ~/cyfr && cd ~/cyfr && cyfr init' 1200 \
    'Install these requirements\? \(yes/no\)' yes "$SUDO_PROMPT" @password 'Choose 1, 2 or 3' 3
  check "cyfr init exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  check "it asks \"Install these requirements?\" once" test "${PANE_ANSWERED[0]}" = 1
  check "sudo asks at most one password (asked ${PANE_ANSWERED[1]})" test "${PANE_ANSWERED[1]}" -le 1
  check "init goes on through the docker group and asks how CYFR is reached" transcript_has init 'How will you reach CYFR\?'
  check "init says what the terminal needs before cyfr up" transcript_has init 'Run `newgrp docker` here, or log out and in again, before `cyfr up`\.'
  pane_step_end init

  step "newgrp docker, then cyfr up"
  pane_type 'newgrp docker' || fail "newgrp was not typed"
  pane_wait '\$ *$' 30 || true
  pane_step up 'cd ~/cyfr && cyfr up' 900
  check "cyfr up exits 0 (it exited $PANE_STATUS)" test "$PANE_STATUS" = 0
  pane_step_end up
  code=$(guest_ssh "curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/" 2>&1)
  check "CYFR answers on its port (HTTP $code)" sh -c '[ "$1" -ge 200 ] && [ "$1" -lt 400 ]' sh "$code"
  check "screenshot ready.png" guest_screenshot ready.png
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

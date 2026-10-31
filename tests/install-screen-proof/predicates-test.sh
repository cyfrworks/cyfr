#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof's predicates (tests/install-screen-proof/
# predicates.sh) and lib.sh's budget on canned evidence, with no guest:
# each passes the evidence a case expects and fails the near misses a
# weaker check would pass.
#
#   sudo_refused, probe_refused, probe_allowed, sudo_step_was
#       a refusal is sudo's own (exit 1 and its words), not SSH's 255, a
#       timeout's 124 or a silent 1; a login or a step is exactly what it
#       records
#   apt_installed_from_archive
#       the installed version's own sources, not any line of the version
#       table: not a newer candidate's archive while another source's
#       version is installed
#   preview_commands, repair_shown_iff_audit, packages_changed
#   interrupt_sentence_true
#       "Nothing was installed." exactly when nothing changed
#   kvm_diagnosis
#       the host change each observed failure needs
#   budget
#       a step's seconds, cut at the case's deadline
#
# Usage: bash tests/install-screen-proof/predicates-test.sh
# Env: INSTALL_SCREEN_PREDICATES, predicates to test in place of
# predicates.sh, which is how a weaker one is shown failing here.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
if [ -n "${INSTALL_SCREEN_PREDICATES:-}" ]; then
  # shellcheck disable=SC1090
  . "$INSTALL_SCREEN_PREDICATES"
fi
GUEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-install-screen-predicates.XXXXXX") || exit 1
trap 'rm -rf "$GUEST_DIR"' EXIT

failures=0
cases=0
# expect pass|fail WHAT COMMAND...
expect() {
  local want=$1 what=$2 code=0
  shift 2
  cases=$((cases + 1))
  "$@" >/dev/null 2>&1 || code=$?
  if { [ "$want" = pass ] && [ "$code" = 0 ]; } || { [ "$want" = fail ] && [ "$code" != 0 ]; }; then
    echo "PASS: $what"
  else
    echo "FAIL: $what (wanted $want, the predicate exited $code)"
    failures=$((failures + 1))
  fi
}
put() { printf '%s\n' "$2" >"$GUEST_DIR/$1"; }

# sudo's refusal, and the probes' and steps' records.
expect pass "sudo-rs's refusal of -n is sudo's own" sudo_refused 1 'sudo-rs: interactive authentication is required'
expect pass "sudo's refusal of -n is sudo's own" sudo_refused 1 'sudo: a password is required'
expect fail "SSH's failure (255) is no refusal" sudo_refused 255 'ssh: connect to host guest port 22: Connection refused'
expect fail "a timeout (124) is no refusal" sudo_refused 124 ''
expect fail "an exit 1 without sudo's words is no refusal" sudo_refused 1 'sudo: unknown user proof'
expect fail "an exit 0 is no refusal" sudo_refused 0 ''
put sudo-probe.txt 'p-refused: sudo -n true exited 1 after 0 password prompts; sudo said: sudo-rs: interactive authentication is required
p-allowed: sudo -n true exited 0 after 0 password prompts; sudo said:
p-ssh: sudo -n true exited 255 after 0 password prompts; sudo said:
p-silent: sudo -n true exited 1 after 0 password prompts; sudo said:
p-prompted: sudo -n true exited 1 after 1 password prompts; sudo said: sudo-rs: interactive authentication is required
s-once: sudo -k true exited 0 after 1 password prompts (1 in the transcript)
s-twice: sudo -k true exited 0 after 2 password prompts (2 in the transcript)
s-unseen: sudo -v exited 0 after 1 password prompts (2 in the transcript)'
expect pass "a probe sudo refused, in its words, is refused" probe_refused p-refused
expect fail "a probe SSH failed (255) is not refused" probe_refused p-ssh
expect fail "a probe that exited 1 without sudo's words is not refused" probe_refused p-silent
expect fail "a probe that showed a prompt is not refused" probe_refused p-prompted
expect fail "a probe that found a login is not refused" probe_refused p-allowed
expect fail "a probe of another name is not this one's" probe_refused p
expect pass "a probe that exited 0 with no prompt found a login" probe_allowed p-allowed
expect fail "a refused probe found no login" probe_allowed p-refused
expect pass "a step that exited 0 after one prompt, one in its transcript" sudo_step_was s-once 0 1
expect fail "a step that asked twice did not ask once" sudo_step_was s-twice 0 1
expect fail "a step whose transcript shows another count did not ask once" sudo_step_was s-unseen 0 1
expect fail "a step that exited 0 did not exit 1" sudo_step_was s-once 1 1

# apt-cache policy: the installed version's own sources.
put docker.txt 'policy docker.io:
policy   Installed: 28.2.2-0ubuntu1
policy   Candidate: 28.2.2-0ubuntu1
policy   Version table:
policy  *** 28.2.2-0ubuntu1 500
policy         500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
policy         100 /var/lib/dpkg/status
policy docker-compose-v2:
policy   Installed: 2.37.1+ds1-0ubuntu2
policy   Candidate: 2.40.0-0ubuntu1
policy   Version table:
policy      2.40.0-0ubuntu1 500
policy         500 http://us.archive.ubuntu.com/ubuntu resolute-updates/universe amd64 Packages
policy  *** 2.37.1+ds1-0ubuntu2 100
policy         100 /var/lib/dpkg/status'
expect pass "docker.io installed from resolute/universe" apt_installed_from_archive "$GUEST_DIR/docker.txt" docker.io 'policy ' universe
expect fail "an installed version only dpkg knows, beside a candidate from the archive" \
  apt_installed_from_archive "$GUEST_DIR/docker.txt" docker-compose-v2 'policy ' universe
put docker-ce.txt 'policy docker.io:
policy   Installed: 5:28.0.0-1~ubuntu.26.04~resolute
policy   Candidate: 5:28.0.0-1~ubuntu.26.04~resolute
policy   Version table:
policy  *** 5:28.0.0-1~ubuntu.26.04~resolute 500
policy         500 https://download.docker.com/linux/ubuntu resolute/stable amd64 Packages
policy         100 /var/lib/dpkg/status
policy      28.2.2-0ubuntu1 500
policy         500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages'
expect fail "an installed version from Docker's own repository, though Ubuntu's archive offers another" \
  apt_installed_from_archive "$GUEST_DIR/docker-ce.txt" docker.io 'policy ' universe
put pockets.txt 'policy docker.io:
policy   Installed: 28.2.2-0ubuntu1.1
policy   Candidate: 28.2.2-0ubuntu1.1
policy   Version table:
policy  *** 28.2.2-0ubuntu1.1 500
policy         500 http://security.ubuntu.com/ubuntu resolute-security/universe amd64 Packages
policy         100 /var/lib/dpkg/status
policy docker-compose-v2:
policy   Installed: 2.40.0-0ubuntu1
policy   Candidate: 2.40.0-0ubuntu1
policy   Version table:
policy  *** 2.40.0-0ubuntu1 500
policy         500 http://archive.ubuntu.com/ubuntu resolute/main amd64 Packages
policy apparmor:
policy   Installed: (none)
policy   Candidate: 5.0.0-0ubuntu1
policy   Version table:
policy      5.0.0-0ubuntu1 500
policy         500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages'
expect pass "an installed version from resolute-security/universe" apt_installed_from_archive "$GUEST_DIR/pockets.txt" docker.io 'policy ' universe
expect fail "an installed version from main when universe is asked" apt_installed_from_archive "$GUEST_DIR/pockets.txt" docker-compose-v2 'policy ' universe
expect fail "a package not installed" apt_installed_from_archive "$GUEST_DIR/pockets.txt" apparmor 'policy ' universe
put other-release.txt 'docker.io:
  Installed: 24.0.7-0ubuntu4
  Candidate: 24.0.7-0ubuntu4
  Version table:
 *** 24.0.7-0ubuntu4 500
        500 http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages
        100 /var/lib/dpkg/status'
expect fail "an installed version from another release" apt_installed_from_archive "$GUEST_DIR/other-release.txt" docker.io '' universe
put cosign.txt 'ii  2.4.1-1
cosign:
  Installed: 2.4.1-1
  Candidate: 2.4.1-1
  Version table:
 *** 2.4.1-1 500
        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
        100 /var/lib/dpkg/status
/usr/bin/cosign'
expect pass "cosign installed from Ubuntu's archive, any component" apt_installed_from_archive "$GUEST_DIR/cosign.txt" cosign '' '[a-z]+'

# Previews, repairs and packages across an interrupted run.
preview='$ cd ~/c3 && cyfr init --no-pull; echo "c3-x exit status $?"
CYFR needs docker.io, the running Docker service and proof'"'"'s membership of the docker group on this machine. These commands make the changes, as root:
  dpkg --configure -a
  apt-get update
  apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends docker.io
  systemctl enable --now docker.service
  usermod -aG docker proof
Members of the docker group control Docker, and so have root'"'"'s power over this machine.
Install these requirements? (yes/no) yes
→ dpkg --configure -a
  usermod -aG docker proof'
put transcript-repair.txt "$preview"
put transcript-group.txt '  usermod -aG docker proof
Install these requirements? (yes/no) yes
→ usermod -aG docker proof'
expect pass "a preview's commands, up to its question" \
  test "$(preview_commands repair | tr '\n' ';')" = 'dpkg --configure -a;apt-get update;apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends docker.io;systemctl enable --now docker.service;usermod -aG docker proof;'
expect pass "a preview of the group change alone" test "$(preview_commands group)" = 'usermod -aG docker proof'
put state-before-repair.txt $'docker.io\t28.2.2-0ubuntu1\tiU \ngroup: \nservice: inactive \naudit:\nThe following packages have been unpacked but not yet configured.'
put state-before-group.txt $'docker.io\t28.2.2-0ubuntu1\tii \ngroup: docker:x:988:\nservice: active enabled\naudit:'
expect pass "a repair previewed when dpkg --audit reported one" repair_shown_iff_audit repair
expect pass "no repair previewed when dpkg --audit reported none" repair_shown_iff_audit group
cp "$GUEST_DIR/transcript-repair.txt" "$GUEST_DIR/transcript-norepair.txt"
cp "$GUEST_DIR/state-before-group.txt" "$GUEST_DIR/state-before-norepair.txt"
expect fail "a repair previewed when dpkg --audit reported none" repair_shown_iff_audit norepair
cp "$GUEST_DIR/transcript-group.txt" "$GUEST_DIR/transcript-missed.txt"
cp "$GUEST_DIR/state-before-repair.txt" "$GUEST_DIR/state-before-missed.txt"
expect fail "no repair previewed when dpkg --audit reported one" repair_shown_iff_audit missed

nothing='Error: Interrupted while installing docker.io, docker-compose-v2, the running Docker service and proof'"'"'s membership of the docker group. Nothing was installed. Run `cyfr init` again to finish'
left='^CError: Interrupted while installing docker.io, docker-compose-v2, the running Docker service and proof'"'"'s membership of the docker group. CYFR left docker.io partly installed. Run `cyfr init` again to finish'
same=$'apparmor\t5.0.0\tii \ngroup: \nservice: inactive \naudit:'
unpacked=$'apparmor\t5.0.0\tii \ndocker.io\t28.2.2-0ubuntu1\tiU \ngroup: \nservice: inactive \naudit:\nThe following packages have been unpacked but not yet configured.'
grouped=$'apparmor\t5.0.0\tii \ngroup: docker:x:988:proof\nservice: inactive \naudit:'
case_of() { # NAME BEFORE AFTER SENTENCE
  put "state-before-$1.txt" "$2"
  put "state-after-$1.txt" "$3"
  put "transcript-$1.txt" "→ apt-get update
$4
$1 exit status 130"
}
case_of nothing-same "$same" "$same" "$nothing"
case_of nothing-changed "$same" "$unpacked" "$nothing"
case_of left-changed "$same" "$unpacked" "$left"
case_of left-same "$same" "$same" "$left"
case_of nothing-grouped "$same" "$grouped" "$nothing"
case_of unfinished "$same" "$same" "${nothing% Run*}"
case_of silent "$same" "$same" ''
expect pass "Nothing was installed, and nothing changed" interrupt_sentence_true nothing-same
expect fail "Nothing was installed, though dpkg's packages changed" interrupt_sentence_true nothing-changed
expect pass "what was left partly installed, after ^C, when dpkg's packages changed" interrupt_sentence_true left-changed
expect fail "something left, though nothing changed" interrupt_sentence_true left-same
expect fail "Nothing was installed, though the account joined the group" interrupt_sentence_true nothing-grouped
expect fail "a sentence that does not say to run cyfr init again" interrupt_sentence_true unfinished
expect fail "no sentence" interrupt_sentence_true silent
expect pass "dpkg's packages changed" packages_changed nothing-changed
expect fail "only the group changed, no package" packages_changed nothing-grouped

# KVM's diagnosis, from the preflight's observations.
preflight() { # NAME SECURITY MODULES ERROR
  put "kvm-$1.txt" "host /dev/kvm: crw-rw---- root:kvm
host account: uid=1000(x) gid=1000(x) groups=1000(x)
host kvm modules: $3
docker context: default, DOCKER_HOST=unset
docker security options: $2
$4"
}
says() { kvm_diagnosis "$GUEST_DIR/kvm-$1.txt" | grep -qF -- "$2"; }
preflight rootless '["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]' 'kvm kvm_intel ' 'qemu-system-x86_64: -accel kvm: Could not access KVM kernel module: Permission denied'
preflight noperm '["name=apparmor","name=seccomp,profile=builtin","name=cgroupns"]' 'kvm kvm_amd ' 'qemu-system-x86_64: -accel kvm: Could not access KVM kernel module: Permission denied'
preflight nomodule '["name=apparmor"]' '' 'qemu-system-x86_64: -accel kvm: Could not access KVM kernel module: No such file or directory'
preflight remote '["name=apparmor"]' 'kvm kvm_intel ' 'docker: Error response from daemon: error gathering device information while adding custom device "/dev/kvm": no such file or directory.'
expect pass "rootless Docker is named" says rootless 'Docker runs rootless here'
expect pass "a denied /dev/kvm names --device and the host's mode" says noperm 'crw-rw---- root:kvm) but QEMU in the container could not open it (permission denied): the daemon must pass --device /dev/kvm read-write'
expect pass "a missing module names lsmod" says nomodule 'neither kvm_intel nor kvm_amd is loaded (lsmod | grep kvm)'
expect pass "a daemon that cannot pass the device is named" says remote 'could not pass /dev/kvm into the container'

# budget: a step's seconds, cut at the case's deadline.
CASE_DEADLINE=$((SECONDS + 100))
budget 60
expect pass "budget 60 with 100 s left is 60" test "$BUDGET" = 60
budget 300
expect pass "budget 300 with about 100 s left is cut to them ($BUDGET)" test "$BUDGET" -ge 98 -a "$BUDGET" -le 100
CASE_DEADLINE=$((SECONDS - 1))
expect fail "budget past the deadline answers 1" budget 10

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]

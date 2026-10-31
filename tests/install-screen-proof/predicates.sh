# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The install-and-screen proof's predicates over the evidence a case has
# written, with no guest to reach: sourced by lib.sh, and run on canned
# evidence by predicates-test.sh. Those that take a NAME read the files
# GUEST_DIR holds for the step NAME.
#
#   sudo_refused STATUS SAID       a `sudo -n true` that sudo itself refused
#   probe_refused / probe_allowed NAME
#                                  a pane probe's record in sudo-probe.txt
#   sudo_step_was NAME STATUS PROMPTS
#                                  a pane sudo step's record there
#   apt_installed_from_archive FILE PACKAGE PREFIX COMPONENT
#                                  apt-cache policy's installed version's
#                                  origin
#   same_record FILE FILE          two records, both written, the same
#   no_cloud_sudoers FILE          the guest's sudoers.d listing, read, names
#                                  no cloud-init file
#   stat_of FILE NAME, owned_as FILE OWNER:GROUP NAME..., mode_is FILE NAME MODE
#                                  a stat record's owner, group and mode
#   pulls_succeeded FILE           init pulled the stack's images through
#                                  Docker
#   project_record_whole FILE      a project record holds what it compares
#   preview_commands NAME          the root commands a preview showed
#   state_whole FILE               a machine-state record is whole
#   packages_changed NAME          dpkg's packages across an interrupted run
#   repair_shown_iff_audit NAME    dpkg --configure -a previewed exactly
#                                  when dpkg --audit reported something
#   interrupt_sentence NAME        an interrupted run's last sentence
#   interrupt_sentence_true NAME   whether it says what the run left
#   kvm_diagnosis FILE             the host change KVM needs, from the
#                                  preflight's observations

# sudo's own refusal of -n when a password is needed, in sudo-rs's words
# or sudo's: what makes a failed `sudo -n true` mean that no login is left
# to reuse, rather than SSH's failure (255) or a timeout (124).
SUDO_REFUSAL='interactive authentication is required|a password is required'

# Whether a `sudo -n true` that exited STATUS, saying SAID, was sudo's own
# refusal: exit 1 and sudo's words for it.
sudo_refused() {
  [ "$1" = 1 ] && grep -qE "$SUDO_REFUSAL" <<<"$2"
}

# Whether the pane probe NAME (lib.sh, pane_sudo_probe) was sudo's own
# refusal: exit 1, no prompt, and sudo's words, so no login was left to
# reuse.
probe_refused() {
  grep -qE "^$1: sudo -n true exited 1 after 0 password prompts; sudo said: .*($SUDO_REFUSAL)" "$GUEST_DIR/sudo-probe.txt"
}

# Whether the pane probe NAME found a login to reuse: exit 0, no prompt.
probe_allowed() {
  grep -qE "^$1: sudo -n true exited 0 after 0 password prompts; " "$GUEST_DIR/sudo-probe.txt"
}

# Whether the pane sudo step NAME (lib.sh, pane_sudo_step) exited STATUS
# after PROMPTS password prompts, as many in its transcript.
sudo_step_was() {
  grep -qE "^$1: .* exited $2 after $3 password prompts \($3 in the transcript\)$" "$GUEST_DIR/sudo-probe.txt"
}

# Whether apt-cache policy's output in the file FILE (each line after the
# prefix PREFIX) shows PACKAGE installed from Ubuntu's archive for this
# release (resolute, resolute-updates or resolute-security) in a
# component matching the extended regex COMPONENT: one of the sources
# listed under its installed version's `***` line, not merely any line of
# its version table.
apt_installed_from_archive() {
  python3 -I -c '
import re, sys
path, package, prefix, component = sys.argv[1:5]
archive = re.compile(r"^\s+\d+ https?://([a-z0-9-]+\.)*ubuntu\.com/ubuntu/? resolute(-updates|-security)?/(%s) " % component)
version_line = re.compile(r"^\s+(\*\*\*\s+)?\S+ -?\d+$")
section, installed, under = None, None, False
for raw in open(path, errors="replace"):
    if not raw.startswith(prefix):
        continue
    line = raw[len(prefix):].rstrip("\n")
    header = re.match(r"^(\S+):$", line)
    if header:
        section, installed, under = header.group(1), None, False
        continue
    if section != package:
        continue
    found = re.match(r"^\s+Installed: (\S+)$", line)
    if found:
        installed = found.group(1)
        continue
    if version_line.match(line):
        under = line.lstrip().startswith("***") and line.split()[-2] == installed
        continue
    if under and archive.match(line):
        sys.exit(0)
sys.exit(1)' "$@"
}

# Whether the files $1 and $2 both hold a record, and the same one: two
# records never written, or written empty, are not one state.
same_record() {
  [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2"
}

# Whether the guest record FILE (lib.sh, guest_boot) holds the listing of
# /etc/sudoers.d, its total and its own `.` entry, and that listing names
# no file of cloud-init's (90-cloud-init-users).
no_cloud_sudoers() {
  local listing
  listing=$(sed -n '/^sudoers\.d:$/,/^getty@tty1: /p' "$1" 2>/dev/null)
  grep -qE '^total [0-9]+$' <<<"$listing" && grep -qE ' \.$' <<<"$listing" && ! grep -qi 'cloud' <<<"$listing"
}

# "OWNER:GROUP MODE" for the one path of the stat record FILE (lines of
# `stat -c "%U:%G %a %n"`) whose last part is NAME; nothing when no path,
# or more than one, has it.
stat_of() {
  awk -v name="$2" '
    NF == 3 && $1 ~ /^[^:]+:[^:]+$/ && $2 ~ /^[0-7]+$/ {
      n = split($3, part, "/")
      if (part[n] == name) { found++; line = $1 " " $2 }
    }
    END { if (found == 1) print line }' "$1" 2>/dev/null
}

# owned_as FILE OWNER:GROUP NAME...: whether the stat record FILE gives
# each NAME that owner and group.
owned_as() {
  local file=$1 owner=$2 name got
  shift 2
  [ "$#" -gt 0 ] || return 1
  for name in "$@"; do
    got=$(stat_of "$file" "$name")
    [ -n "$got" ] && [ "${got% *}" = "$owner" ] || return 1
  done
}

# mode_is FILE NAME MODE: whether the stat record FILE gives NAME the
# octal MODE.
mode_is() {
  local got
  got=$(stat_of "$1" "$2")
  [ -n "$got" ] && [ "${got#* }" = "$3" ]
}

# Whether init's transcript FILE shows it pulled the stack's images through
# Docker: a `Pulling REF ...` line at least, docker pull's own Status line
# for each REF's digest (REF itself when it names none), and no `Warning:
# failed to pull`, in any case, which init prints when a pull fails and
# carries on. An init that skipped its pulls, or ran without the docker
# group, fails it.
pulls_succeeded() {
  local file=$1 ref want n=0
  if grep -qi 'warning: failed to pull' "$file" 2>/dev/null; then return 1; fi
  while IFS= read -r ref; do
    n=$((n + 1))
    want=$(grep -oE '@sha256:[0-9a-f]{64}$' <<<"$ref") || want=$ref
    grep -E '^Status: (Downloaded newer image|Image is up to date) for ' "$file" | grep -qF -- "$want" || return 1
  done < <(sed -nE 's/^Pulling (.+) \.\.\.$/\1/p' "$file" 2>/dev/null)
  [ "$n" -gt 0 ]
}

# Whether the project record FILE (run.sh, case 2's second init) holds the
# sums of .env, docker-compose.yml and Caddyfile and a running container's
# id at least, so that two of them compare the project and the stack.
project_record_whole() {
  [ "$(grep -cE '^[0-9a-f]{64}  (\.env|docker-compose\.yml|Caddyfile)$' "$1" 2>/dev/null)" = 3 ] &&
    grep -qE '^[0-9a-f]{64}$' "$1"
}

# The root commands the run NAME's preview showed before its question, one
# per line.
preview_commands() {
  sed '/Install these requirements/q' "$GUEST_DIR/transcript-$1.txt" |
    sed -nE 's/^  ((apt-get|dpkg|systemctl|usermod) .*)$/\1/p'
}

# Whether the machine-state record FILE (run.sh, guest_state) is whole:
# dpkg's packages, then the group, service and audit lines.
state_whole() {
  grep -q $'\t' "$1" 2>/dev/null && grep -q '^group: ' "$1" && grep -q '^service: ' "$1" && grep -qx 'audit:' "$1"
}

# Whether dpkg's packages, the first part of run.sh's guest_state record,
# differ after the run NAME from before it, both records whole.
packages_changed() {
  state_whole "$GUEST_DIR/state-before-$1.txt" && state_whole "$GUEST_DIR/state-after-$1.txt" &&
    ! cmp -s <(sed '/^group: /,$d' "$GUEST_DIR/state-before-$1.txt") <(sed '/^group: /,$d' "$GUEST_DIR/state-after-$1.txt")
}

# Whether the run NAME's preview repairs an interrupted package
# installation (dpkg --configure -a) exactly when dpkg --audit reported one
# before it.
repair_shown_iff_audit() {
  local audit shown
  state_whole "$GUEST_DIR/state-before-$1.txt" || return 1
  audit=$(sed -n '/^audit:$/,$p' "$GUEST_DIR/state-before-$1.txt" | sed 1d | grep -c .)
  shown=$(preview_commands "$1" | grep -cx 'dpkg --configure -a')
  if [ "$audit" -gt 0 ]; then [ "$shown" = 1 ]; else [ "$shown" = 0 ]; fi
}

# The interrupted run NAME's last sentence.
interrupt_sentence() {
  grep -E '^(\^C)?(Error: )?Interrupted while installing ' "$GUEST_DIR/transcript-$1.txt" | tail -n 1
}

# Whether the interrupted run NAME's sentence says what the interrupt left
# and to run cyfr init again: "Nothing was installed." exactly when the
# machine's state (run.sh's guest_state, both records whole) is as it was
# before the run, else what CYFR did ("CYFR installed ...", "left ...
# partly installed", ...).
interrupt_sentence_true() {
  local sentence
  state_whole "$GUEST_DIR/state-before-$1.txt" && state_whole "$GUEST_DIR/state-after-$1.txt" || return 1
  sentence=$(interrupt_sentence "$1")
  [[ $sentence == *'. Run `cyfr init` again to finish'* ]] || return 1
  if cmp -s "$GUEST_DIR/state-before-$1.txt" "$GUEST_DIR/state-after-$1.txt"; then
    [[ $sentence == *'. Nothing was installed. Run `cyfr init` again to finish'* ]]
  else
    [[ $sentence != *'Nothing was installed'* ]] && [[ $sentence =~ \.\ CYFR\ [^.]*(installed|left|finished|started|added) ]]
  fi
}

# The host change KVM needs, from what the preflight file FILE observed
# (lib.sh, proof_kvm_preflight).
kvm_diagnosis() {
  local file=$1 said
  said=$(grep -iE 'kvm|device|permission|denied|error' "$file" | grep -vE '^(host|docker|container) ' | tail -n 1)
  if grep -q 'name=rootless' "$file"; then
    echo "Docker runs rootless here, and a rootless daemon's containers cannot open the host's /dev/kvm: run the proof against this machine's rootful daemon (docker context use default)"
  elif grep -q 'name=userns' "$file"; then
    echo "the Docker daemon remaps its containers' users (userns-remap), so they cannot open the host's /dev/kvm: run the proof against a daemon without remapping"
  elif ! grep -qE '^host kvm modules: .*kvm_(intel|amd)' "$file"; then
    echo "the host has /dev/kvm but neither kvm_intel nor kvm_amd is loaded (lsmod | grep kvm): turn on virtualization in the firmware and load the module"
  elif grep -qiE 'error gathering device information|/dev/kvm.*(no such file|not found)' "$file"; then
    echo "the Docker daemon could not pass /dev/kvm into the container (--device /dev/kvm), so it does not run on this machine (the context or DOCKER_HOST names another): run the proof against this machine's own daemon"
  elif grep -qi 'permission denied' "$file"; then
    echo "the host's /dev/kvm exists ($(sed -n 's/^host \/dev\/kvm: //p' "$file"), gid $(sed -n 's/^host \/dev\/kvm gid: //p' "$file")) but QEMU in the container could not open it (permission denied): the container's user joins that gid, so the device's mode must give its group read and write, and the daemon must pass --device /dev/kvm read-write, with no device rule or security profile that denies it"
  else
    echo "QEMU in the container could not start a KVM machine${said:+ (it said: $said)}: check that the daemon may pass --device /dev/kvm (no rootless Docker) and that the kvm module is loaded (lsmod | grep kvm)"
  fi
}

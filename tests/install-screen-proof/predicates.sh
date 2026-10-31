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
#   preview_commands NAME          the root commands a preview showed
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

# The root commands the run NAME's preview showed before its question, one
# per line.
preview_commands() {
  sed '/Install these requirements/q' "$GUEST_DIR/transcript-$1.txt" |
    sed -nE 's/^  ((apt-get|dpkg|systemctl|usermod) .*)$/\1/p'
}

# Whether dpkg's packages, the first part of run.sh's guest_state record,
# differ after the run NAME from before it.
packages_changed() {
  ! cmp -s <(sed '/^group: /,$d' "$GUEST_DIR/state-before-$1.txt") <(sed '/^group: /,$d' "$GUEST_DIR/state-after-$1.txt")
}

# Whether the run NAME's preview repairs an interrupted package
# installation (dpkg --configure -a) exactly when dpkg --audit reported one
# before it.
repair_shown_iff_audit() {
  local audit shown
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
# machine's state (run.sh's guest_state) is as it was before the run, else
# what CYFR did ("CYFR installed ...", "left ... partly installed", ...).
interrupt_sentence_true() {
  local sentence
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
    echo "the Docker daemon remaps its containers' root (userns-remap), so their root cannot open the host's /dev/kvm: run the proof against a daemon without remapping"
  elif ! grep -qE '^host kvm modules: .*kvm_(intel|amd)' "$file"; then
    echo "the host has /dev/kvm but neither kvm_intel nor kvm_amd is loaded (lsmod | grep kvm): turn on virtualization in the firmware and load the module"
  elif grep -qiE 'error gathering device information|/dev/kvm.*(no such file|not found)' "$file"; then
    echo "the Docker daemon could not pass /dev/kvm into the container (--device /dev/kvm), so it does not run on this machine (the context or DOCKER_HOST names another): run the proof against this machine's own daemon"
  elif grep -qi 'permission denied' "$file"; then
    echo "the host's /dev/kvm exists ($(sed -n 's/^host \/dev\/kvm: //p' "$file")) but QEMU in the container could not open it (permission denied): the daemon must pass --device /dev/kvm read-write, with no device rule or security profile that denies it"
  else
    echo "QEMU in the container could not start a KVM machine${said:+ (it said: $said)}: check that the daemon may pass --device /dev/kvm (no rootless Docker) and that the kvm module is loaded (lsmod | grep kvm)"
  fi
}

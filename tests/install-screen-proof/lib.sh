# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The install-and-screen proof's helpers, sourced by run.sh after
# cleanup.sh. A case is one function made of them: proof_image_build,
# proof_kvm_preflight, proof_base_fetch and proof_seed once per run, then
# per guest guest_boot, which starts a fresh guest and records that it runs
# under KVM and reached its login prompt; tty1_login, which signs the test
# account in on the guest's own screen and starts the tmux session `proof`
# there; the pane_ helpers, which type into that terminal and read it back
# over SSH, so what a case types reaches the program under test through the
# guest's terminal as a person's typing does; guest_ssh and guest_copy_in
# for evidence and files apart from the terminal; guest_screenshot; and
# proof_guest_stop (cleanup.sh). check records each verdict.
#
# They read PROOF_PREFIX, IMAGE, VOLUME, WORK, OUT and HERE, which run.sh
# sets, and set GUEST and GUEST_DIR for the guest under way. A
# guest's evidence goes under GUEST_DIR.

# The guests' base and the host's cache of it (CLOUD_*, BASE_DIR).
# shellcheck source=base-image.sh
. "$HERE/base-image.sh"

PROOF_USER=proof
# A password prompt of sudo-rs or of sudo, which run.sh's cases read.
# shellcheck disable=SC2034
SUDO_PROMPT='\[sudo[^]]*\] [Pp]assword'

GUEST="" GUEST_PART="" GUEST_DIR=""
CHECK_FAILURES=0
PANE_ANSWERED=() PANE_SCREEN=""

step() { printf '\n==> %s\n' "$*"; }
ok() { printf 'ok: %s\n' "$*"; }
fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# Records a verdict line in the guest's results.txt and on stdout.
record() {
  printf '%s: %s\n' "$1" "$2" | tee -a "$GUEST_DIR/results.txt"
}

# check DESCRIPTION COMMAND...: PASS when COMMAND succeeds, else FAIL,
# counted in CHECK_FAILURES. A failed check does not end the run.
check() {
  local what=$1
  shift
  if "$@"; then
    record PASS "$what"
  else
    record FAIL "$what"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  fi
}

# The value at the key path $2... of the JSON $1, as JSON.
json_at() {
  python3 -I -c '
import json, sys
value = json.loads(sys.argv[1])
for key in sys.argv[2:]:
    value = value.get(key) if isinstance(value, dict) else None
print(json.dumps(value))' "$@"
}

proof_image_build() {
  step "building $IMAGE from $HERE/Dockerfile"
  proof_own image "$IMAGE" || fail "the image $IMAGE cannot be the run's"
  proof_fg docker build --build-arg "APT_REFRESH=$(date -u +%F)" --tag "$IMAGE" "$HERE" >"$OUT/image-build.log" 2>&1 || {
    tail -n 40 "$OUT/image-build.log" >&2
    fail "the image $IMAGE did not build"
  }
  ok "built $IMAGE"
}

# QEMU in the container creates a KVM machine before any guest is booted.
# Without it nothing later can run, and the host is left as it is.
proof_kvm_preflight() {
  step "KVM inside the container"
  proof_own container "${PROOF_PREFIX}kvm" || fail "the container ${PROOF_PREFIX}kvm cannot be the run's"
  {
    echo "host /dev/kvm: $(stat -c '%A %U:%G' /dev/kvm)"
    echo "host account: $(id)"
  } >"$OUT/kvm-preflight.txt"
  if ! proof_fg docker run --rm --init --name "${PROOF_PREFIX}kvm" --network none --device /dev/kvm "$IMAGE" \
    /proof/kvm-check.sh >>"$OUT/kvm-preflight.txt" 2>&1; then
    cat "$OUT/kvm-preflight.txt" >&2
    fail "KVM did not start inside the container; no later case can run, and nothing on the host was changed ($OUT/kvm-preflight.txt)"
  fi
  qmp_says_kvm "$OUT/kvm-preflight.txt" || fail "QEMU in the container started without KVM ($OUT/kvm-preflight.txt)"
  ok "QEMU in the container runs with KVM: $(grep -m 1 '^QEMU emulator' "$OUT/kvm-preflight.txt")"
}

# Whether a QMP reply line of the file $1 says KVM is present and enabled.
qmp_says_kvm() {
  python3 -I -c '
import json, sys
for line in open(sys.argv[1], errors="replace"):
    try:
        reply = json.loads(line)
    except ValueError:
        continue
    value = reply.get("return") if isinstance(reply, dict) else None
    if isinstance(value, dict) and value.get("enabled") is True and value.get("present") is True:
        sys.exit(0)
sys.exit(1)' "$1"
}

# The base the host's cache holds, verified inside the container with no
# network, read-only. The run downloads nothing itself: fetch-base.sh
# fills the cache outside any lane, so a held lane never waits on the
# network.
proof_base_verify() {
  step "the pinned Ubuntu 26.04 cloud image, from the host's cache $BASE_DIR, verified"
  if [ ! -f "$BASE_DIR/$CLOUD_IMAGE" ]; then
    echo "install-screen proof: the base image is not in $BASE_DIR; run tests/install-screen-proof/fetch-base.sh first, outside any lane" >&2
    exit 69
  fi
  proof_own volume "$VOLUME" || fail "the volume $VOLUME cannot be the run's"
  docker volume create "$VOLUME" >/dev/null || fail "the volume $VOLUME was not made"
  proof_own container "${PROOF_PREFIX}verify" || fail "the container ${PROOF_PREFIX}verify cannot be the run's"
  proof_fg docker run --rm --init --name "${PROOF_PREFIX}verify" --network none --volume "$BASE_DIR:/base:ro" "$IMAGE" \
    /proof/verify-base.sh "$CLOUD_IMAGE" "$CLOUD_IMAGE_SHA256" >"$OUT/base-image.txt" 2>&1 || {
    tail -n 20 "$OUT/base-image.txt" >&2
    fail "the cached base image did not verify ($OUT/base-image.txt); run tests/install-screen-proof/fetch-base.sh again"
  }
  ok "$CLOUD_IMAGE: signature good, sum $CLOUD_IMAGE_SHA256"
}

# The test account's SSH key and password, made for this run. The password
# is hexadecimal, so QMP types it one key per character.
proof_seed() {
  mkdir -m 700 "$WORK/seed" || fail "no seed directory"
  ssh-keygen -q -t ed25519 -N '' -C install-screen-proof -f "$WORK/key" || fail "no SSH key"
  cp "$WORK/key.pub" "$WORK/seed/authorized_key" || fail "no SSH key"
  od -An -N12 -tx1 /dev/urandom | tr -d ' \n' >"$WORK/password" || fail "no password"
  cp "$WORK/password" "$WORK/seed/password" || fail "no password"
}

guest_running() {
  [ "$(docker container inspect --format '{{.State.Running}}' "$GUEST" 2>/dev/null)" = true ]
}

# guest_qmp COMMAND [ARGUMENTS-JSON]: the command's return value as JSON.
guest_qmp() {
  proof_fg timeout 90 docker exec --env "QMP_WAIT=${QMP_WAIT:-30}" "$GUEST" python3 /proof/qmp.py "$PROOF_QMP_SOCKET" "$@"
}

# Types standard input's text on the guest's keyboard.
guest_keys() {
  proof_fg timeout 120 docker exec -i "$GUEST" python3 /proof/qmp.py "$PROOF_QMP_SOCKET" type
}

# guest_ssh_in COMMAND: COMMAND in the test account's shell over SSH,
# without a terminal, standard input passed on; guest_ssh gives it none.
# Every call shares one SSH connection to the guest (ControlMaster), so a
# step's reads each second open no new connection through QEMU's user
# networking; the teardown ends it (PROOF_SSH_CONTROLS).
# The connection reaches the guest through its container: QEMU forwards
# the container's loopback port 2222 to the guest's SSH, and a connection
# from loopback reaches the guest from QEMU's own 10.0.2.2. One from any
# other address would keep that address, the host's Docker bridge's, which
# the guest routes into its own docker0 once Docker is installed there.
guest_ssh_in() {
  proof_fg timeout "${GUEST_SSH_TIMEOUT:-120}" ssh -F /dev/null -T -i "$WORK/key" \
    -o "ProxyCommand=docker exec -i $GUEST nc 127.0.0.1 2222" \
    -o ControlMaster=auto -o "ControlPath=$WORK/ssh-$GUEST_PART" -o ControlPersist=yes \
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    "$PROOF_USER@guest" "$1"
}
guest_ssh() { guest_ssh_in "$1" </dev/null; }

# Ends the shared connection, so the next call logs in afresh: a login
# reads the account's groups once, and a session of the shared connection
# keeps those of the login that opened it.
guest_ssh_relogin() {
  timeout 10 ssh -F /dev/null -o "ControlPath=$WORK/ssh-$GUEST_PART" -O exit guest >/dev/null 2>&1 || true
}

# guest_copy_in SOURCE DEST: the host file SOURCE as DEST in the guest,
# relative to the test account's home.
guest_copy_in() {
  guest_ssh_in "cat >$(printf '%q' "$2")" <"$1"
}

# guest_screenshot NAME: the guest's display as the PNG GUEST_DIR/NAME.
guest_screenshot() {
  local name=$1
  guest_qmp screendump "{\"filename\": \"/case/$name\", \"format\": \"png\"}" >/dev/null &&
    docker cp "$GUEST:/case/$name" "$GUEST_DIR/$name" >/dev/null 2>&1 &&
    [ "$(od -An -N8 -tx1 "$GUEST_DIR/$name" | tr -d ' \n')" = 89504e470d0a1a0a ]
}

# guest_packages FILE: every package dpkg knows, its version and state.
guest_packages() {
  guest_ssh 'dpkg-query -W -f "\${binary:Package}\t\${Version}\t\${db:Status-Abbrev}\n" | sort' >"$GUEST_DIR/$1"
}

# guest_boot PART MEMORY_MIB DISK_SIZE: a fresh guest named for PART, its
# evidence in OUT/PART, up until its tty1 waits at the login prompt.
guest_boot() {
  local part=$1 memory=$2 disk=$3 closes
  GUEST="${PROOF_PREFIX}qemu-$part"
  GUEST_PART=$part
  GUEST_DIR="$OUT/$part"
  CHECK_FAILURES=0
  mkdir "$GUEST_DIR" || fail "the evidence directory $GUEST_DIR exists already"
  step "$part: a fresh guest under KVM ($memory MiB, a $disk disk, 4 vCPUs)"
  proof_own container "$GUEST" "$GUEST_DIR" || fail "the container $GUEST cannot be the run's"
  docker create --init --name "$GUEST" --device /dev/kvm \
    --volume "$VOLUME:/disk" --volume "$BASE_DIR:/base:ro" "$IMAGE" \
    /proof/guest-boot.sh "$part" "$memory" "$disk" 4 "$CLOUD_IMAGE" >/dev/null ||
    fail "the QEMU container $GUEST was not made"
  docker cp "$WORK/seed/." "$GUEST:/seed" >/dev/null || fail "the guest's seed was not copied into $GUEST"
  docker start "$GUEST" >/dev/null || fail "the QEMU container $GUEST did not start"

  # A QEMU that cannot open /dev/kvm exits rather than answer QMP.
  closes=$((SECONDS + 120))
  until QMP_WAIT=2 guest_qmp query-status >"$GUEST_DIR/qmp-status.json" 2>/dev/null; do
    if ! guest_running; then
      docker logs "$GUEST" >"$GUEST_DIR/qemu.log" 2>&1
      fail "QEMU stopped in $GUEST before it answered QMP: $(tail -n 20 "$GUEST_DIR/qemu.log")"
    fi
    [ "$SECONDS" -lt "$closes" ] || fail "QEMU in $GUEST answered no QMP within 120 s"
    sleep 1
  done
  guest_kvm_evidence

  PROOF_SSH_CONTROLS+=("$WORK/ssh-$part")
  closes=$((SECONDS + 300))
  until guest_ssh true 2>/dev/null; do
    guest_running || fail "QEMU stopped in $GUEST before the guest's SSH answered"
    [ "$SECONDS" -lt "$closes" ] || fail "the guest's SSH did not answer within 300 s"
    sleep 2
  done
  GUEST_SSH_TIMEOUT=600 guest_ssh 'cloud-init status --wait --long' >"$GUEST_DIR/cloud-init.txt" 2>&1
  check "$part: cloud-init finished" grep -qE '^\.*status: done' "$GUEST_DIR/cloud-init.txt"
  guest_ssh 'cat /etc/os-release; uname -a; echo "virt: $(systemd-detect-virt)"
    lscpu | grep -i -E "^(hypervisor vendor|virtualization type)"
    echo "sudo: $(readlink -f /usr/bin/sudo)"; sudo --version 2>&1 | head -n 1
    echo "id: $(id)"; echo "sudoers.d:"; ls -la /etc/sudoers.d
    echo "getty@tty1: $(systemctl is-active getty@tty1.service)"
    sudo -n true 2>&1; echo "sudo -n true status: $?"' >"$GUEST_DIR/guest.txt" 2>&1
  check "$part: the guest is Ubuntu 26.04" grep -qx 'VERSION_ID="26.04"' "$GUEST_DIR/guest.txt"
  check "$part: the guest runs under KVM (systemd-detect-virt)" grep -qx 'virt: kvm' "$GUEST_DIR/guest.txt"
  check "$part: the test account is in its own group and sudo alone" \
    grep -qE '^id: uid=[0-9]+\(proof\) gid=[0-9]+\(proof\) groups=[0-9]+\(proof\),[0-9]+\(sudo\)$' "$GUEST_DIR/guest.txt"
  check "$part: no sudoers rule lets the account skip its password (sudo -n true fails)" \
    grep -qE '^sudo -n true status: [1-9][0-9]*$' "$GUEST_DIR/guest.txt"
  check "$part: cloud-init wrote no sudoers file" guest_no_cloud_sudoers
  check "$part: tty1's getty runs" grep -qx 'getty@tty1: active' "$GUEST_DIR/guest.txt"

  closes=$((SECONDS + 60))
  until docker exec "$GUEST" grep -q 'cyfr-proof login:' /case/serial.log 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || break
    sleep 1
  done
  check "$part: the guest reached its login prompt (serial console)" \
    docker exec "$GUEST" grep -q 'cyfr-proof login:' /case/serial.log
  check "$part: screenshot login-prompt.png" guest_screenshot login-prompt.png
}

guest_no_cloud_sudoers() {
  ! sed -n '/^sudoers.d:/,/^getty@tty1:/p' "$GUEST_DIR/guest.txt" | grep -qi 'cloud'
}

# QEMU's own account of KVM inside the container, in GUEST_DIR/kvm.txt.
guest_kvm_evidence() {
  local file="$GUEST_DIR/kvm.txt" kvm
  kvm=$(guest_qmp query-kvm 2>&1) || kvm=""
  {
    echo "host /dev/kvm: $(stat -c '%A %U:%G' /dev/kvm)"
    echo "host account: $(id)"
    echo "QMP query-kvm: $kvm"
    echo "QMP query-version: $(guest_qmp query-version 2>&1)"
    docker exec "$GUEST" cat /case/container.txt
    echo "QEMU's descriptors on KVM:"
    docker exec "$GUEST" sh -c 'pid=$(cat /run/proof/qemu.pid) && echo "pid $pid" && for fd in /proc/$pid/fd/*; do readlink "$fd"; done | grep kvm | sort | uniq -c'
    echo "QEMU's command line:"
    docker exec "$GUEST" sh -c 'tr "\0" " " </proc/$(cat /run/proof/qemu.pid)/cmdline; echo'
  } >"$file" 2>&1
  check "$GUEST_PART: QEMU runs the guest with KVM inside the container (query-kvm)" kvm_enabled "$kvm"
  check "$GUEST_PART: QEMU holds /dev/kvm open" grep -qE '^ *[0-9]+ /dev/kvm$' "$file"
}

# Whether the query-kvm answer $1 says KVM is present and enabled.
kvm_enabled() {
  [ -n "$1" ] && [ "$(json_at "$1" enabled 2>/dev/null)/$(json_at "$1" present 2>/dev/null)" = true/true ]
}

# Signs the test account in on tty1 by typing at its getty, then starts the
# tmux session `proof` on that terminal; the screen then shows the session.
tty1_login() {
  local _attempt closes signed=""
  guest_ssh 'printf "%s\n" "set -g history-limit 50000" "set -g status off" >~/.tmux.conf' ||
    fail "the tmux settings were not written"
  for _attempt in 1 2 3; do
    printf '%s\n' "$PROOF_USER" | guest_keys || fail "QMP did not type on the guest's keyboard"
    sleep 3
    { cat "$WORK/password"; printf '\n'; } | guest_keys || fail "QMP did not type on the guest's keyboard"
    closes=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$closes" ]; do
      if guest_ssh "pgrep -u $PROOF_USER -t tty1 -x bash" >/dev/null 2>&1; then
        signed=1
        break 2
      fi
      sleep 1
    done
  done
  if [ -z "$signed" ]; then
    guest_screenshot tty1-login-failed.png || true
    fail "the test account did not sign in on tty1 after three tries ($GUEST_DIR/tty1-login-failed.png)"
  fi
  printf '%s\n' 'tmux new-session -s proof' | guest_keys || fail "QMP did not type on the guest's keyboard"
  closes=$((SECONDS + 60))
  until guest_ssh 'tmux has-session -t proof' 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "no tmux session proof started on tty1 within 60 s"
    sleep 1
  done
  pane_wait '\$ *$' 30 || fail "the shell in the tmux session drew no prompt within 30 s"
  guest_ssh 'tmux list-clients -F "#{client_tty} #{session_name}"' >"$GUEST_DIR/tmux-clients.txt" 2>&1
  check "$GUEST_PART: the tmux session proof is shown on tty1" grep -qx '/dev/tty1 proof' "$GUEST_DIR/tmux-clients.txt"
}

# The pane's whole history, wrapped lines joined. A read that fails is
# recorded in GUEST_DIR/ssh-failures.txt, with the guest's view of SSH
# from QEMU's user network, the first time in a row it fails.
PANE_READ_FAILING=""
pane_capture() {
  local out
  if out=$(guest_ssh 'tmux capture-pane -p -J -t proof -S - -E -' 2>"$WORK/capture.err"); then
    PANE_READ_FAILING=""
    printf '%s\n' "$out"
    return 0
  fi
  if [ -z "$PANE_READ_FAILING" ]; then
    PANE_READ_FAILING=1
    {
      echo "== $(date -u +%FT%TZ), ${SECONDS}s into the run: a pane read failed"
      cat "$WORK/capture.err"
      echo "-- QEMU's user network:"
      guest_qmp human-monitor-command '{"command-line": "info usernet"}' 2>&1
      echo "-- ssh -v:"
      timeout 20 ssh -v -F /dev/null -T -i "$WORK/key" -o "ProxyCommand=docker exec -i $GUEST nc 127.0.0.1 2222" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "$PROOF_USER@guest" true 2>&1 | tail -n 25
    } >>"$GUEST_DIR/ssh-failures.txt" 2>&1
  fi
  return 1
}

pane_save() {
  pane_capture >"$GUEST_DIR/$1" 2>&1
}

# Types the line $1 into the pane, then Enter.
pane_type() {
  guest_ssh "tmux send-keys -t proof -l -- $(printf '%q' "$1") && tmux send-keys -t proof Enter"
}

# Types the test account's password into the pane, then Enter. It passes
# through a tmux buffer from SSH's standard input, never a command line.
pane_password() {
  guest_ssh_in 'tmux load-buffer -b proof-password - && tmux paste-buffer -d -b proof-password -t proof && tmux send-keys -t proof Enter' <"$WORK/password"
}

# pane_wait REGEX SECONDS: whether a pane line matches the extended REGEX
# within SECONDS; PANE_SCREEN holds the last read.
pane_wait() {
  local closes=$((SECONDS + $2))
  while :; do
    PANE_SCREEN=$(pane_capture 2>/dev/null) || PANE_SCREEN=""
    grep -qE -- "$1" <<<"$PANE_SCREEN" && return 0
    [ "$SECONDS" -lt "$closes" ] || return 1
    sleep 1
  done
}

# pane_converse SECONDS DONE [PATTERN ANSWER]...: reads the pane each
# second until a line matches the extended regex DONE, within SECONDS.
# Whenever more lines match a PATTERN than it has answered, it types that
# PATTERN's ANSWER: a line, or for @password the test account's password.
# PANE_ANSWERED[i] counts the answers to the i-th PATTERN, which is the
# number of times what it matches was asked; PANE_SCREEN holds the last
# read. Returns 1 at the deadline, or when a PATTERN is asked a fourth time.
pane_converse() {
  local seconds=$1 done_re=$2 closes i seen
  local -a patterns=() answers=()
  shift 2
  while [ "$#" -ge 2 ]; do
    patterns+=("$1")
    answers+=("$2")
    shift 2
  done
  PANE_ANSWERED=() PANE_FIRST=() PANE_DONE_AT="" PANE_MARK_AT=()
  for i in "${!patterns[@]}"; do PANE_ANSWERED[i]=0; done
  PANE_START=$SECONDS
  closes=$((SECONDS + seconds))
  while :; do
    PANE_SCREEN=$(pane_capture 2>/dev/null) || PANE_SCREEN=""
    for i in "${!PANE_MARKS[@]}"; do
      [ -n "${PANE_MARK_AT[i]:-}" ] || ! grep -qE -- "${PANE_MARKS[i]}" <<<"$PANE_SCREEN" || PANE_MARK_AT[i]=$SECONDS
    done
    for i in "${!patterns[@]}"; do
      seen=$(grep -cE -- "${patterns[i]}" <<<"$PANE_SCREEN")
      [ "$seen" -gt 0 ] && [ -z "${PANE_FIRST[i]:-}" ] && PANE_FIRST[i]=$SECONDS
      [ "$seen" -gt "${PANE_ANSWERED[i]}" ] || continue
      [ "${PANE_ANSWERED[i]}" -lt 3 ] || return 1
      if [ "${answers[i]}" = @password ]; then
        pane_password || return 1
      else
        pane_type "${answers[i]}" || return 1
      fi
      PANE_ANSWERED[i]=$((PANE_ANSWERED[i] + 1))
    done
    if grep -qE -- "$done_re" <<<"$PANE_SCREEN"; then
      PANE_DONE_AT=$SECONDS
      return 0
    fi
    [ "$SECONDS" -lt "$closes" ] || return 1
    sleep 1
  done
}

# PANE_MARKS holds extended regexes whose first sighting pane_converse
# times, in PANE_MARK_AT, as PANE_FIRST times each answered pattern's and
# PANE_DONE_AT the end's, all in SECONDS. A step's evidence is its own: the
# pane's history is saved as transcript-NAME.txt and cleared, so the next
# step counts only its own prompts.
PANE_MARKS=() PANE_MARK_AT=() PANE_FIRST=() PANE_DONE_AT="" PANE_START=""
pane_step_end() {
  pane_save "transcript-$1.txt"
  pane_type 'clear' && guest_ssh 'tmux clear-history -t proof' || return 1
  pane_wait '\$ *$' 30
}

# The step NAME: the line LINE typed into the pane, ending at
# "NAME exit status N", within SECONDS, answering [PATTERN ANSWER]...
# Leaves the exit status in PANE_STATUS and the transcript in
# GUEST_DIR/transcript-NAME.txt.
pane_step() {
  local name=$1 line=$2 seconds=$3
  shift 3
  PANE_STATUS=""
  pane_type "$line; echo \"$name exit status \$?\"" || fail "$name: the line was not typed"
  if ! pane_converse "$seconds" "^$name exit status [0-9]+" "$@"; then
    pane_save "transcript-$name.txt"
    guest_screenshot "$name-stuck.png" || true
    fail "$name: no exit within $seconds s, or a question was asked a fourth time ($GUEST_DIR/transcript-$name.txt)"
  fi
  PANE_STATUS=$(grep -oE "^$name exit status [0-9]+" <<<"$PANE_SCREEN" | tail -n 1 | awk '{print $NF}')
  pane_save "transcript-$name.txt"
}

# This tree's cyfr for the guests, built once per run, stamped as the
# published release INSTALL_VERSION so that cyfr init fetches and verifies
# that release's scaffold under production trust. Its own bytes are not a
# signed release: cases that use it are stand-ins for the candidate's
# delivery, which case 1 proves through the installer.
CANDIDATE_BIN=""
candidate_build() {
  [ -z "$CANDIDATE_BIN" ] || return 0
  step "this tree's cyfr for linux/amd64, stamped $INSTALL_VERSION (stand-in for a signed candidate)"
  CANDIDATE_BIN="$WORK/cyfr"
  proof_fg env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -C "$ROOT/apps/codex" -trimpath \
    -ldflags "-s -w -X github.com/cyfr/codex/internal/version.Version=$INSTALL_VERSION -X github.com/cyfr/codex/internal/version.Commit=$(git -C "$ROOT" rev-parse --short HEAD)" \
    -o "$CANDIDATE_BIN" . >"$OUT/candidate-build.log" 2>&1 || fail "the candidate did not build ($OUT/candidate-build.log)"
  {
    echo "built from $ROOT at $(git -C "$ROOT" rev-parse HEAD), with these changes:"
    git -C "$ROOT" status --short -- apps/codex
    echo "sha256: $(sha256sum <"$CANDIDATE_BIN" | cut -d ' ' -f 1)"
  } >"$OUT/candidate.txt"
  ok "built the candidate, $(sed -n 's/^sha256: //p' "$OUT/candidate.txt")"
}

# guest_root COMMAND: COMMAND as root over SSH, the harness's own setup or
# its holders of locks, the password on sudo's standard input, its output
# in GUEST_DIR/root.txt; then every
# sudo timestamp of the account is removed (sudo -K), so no probe of the
# terminal's cached login sees one the harness made.
guest_root() {
  echo "== $1" >>"$GUEST_DIR/root.txt"
  { cat "$WORK/password"; printf '\n'; } | guest_ssh_in "sudo -S -k -p '' sh -c $(printf '%q' "$1")" >>"$GUEST_DIR/root.txt" 2>&1
  local status=$?
  echo "== status $status" >>"$GUEST_DIR/root.txt"
  guest_ssh 'sudo -K' >/dev/null 2>&1 || true
  return "$status"
}

# The candidate at /usr/local/bin/cyfr, root's and mode 0755, where the
# installer puts it on this system.
guest_provision_candidate() {
  candidate_build
  guest_copy_in "$CANDIDATE_BIN" cyfr-candidate || fail "the candidate was not copied into the guest"
  guest_root "install -o root -g root -m 0755 /home/$PROOF_USER/cyfr-candidate /usr/local/bin/cyfr && rm /home/$PROOF_USER/cyfr-candidate" ||
    fail "the candidate was not installed at /usr/local/bin/cyfr"
  guest_ssh '/usr/local/bin/cyfr --version' >"$GUEST_DIR/cyfr.txt" 2>&1
  check "$GUEST_PART: /usr/local/bin/cyfr is the candidate, reporting $INSTALL_VERSION" grep -qF "$INSTALL_VERSION" "$GUEST_DIR/cyfr.txt"
}

# The boot's journal and apt's history, read once nothing else is to be
# observed: reading the system journal takes root, so this is the run's
# one elevation outside the terminal, its password on sudo's standard
# input, after every probe of cached authorization.
guest_journal() {
  { cat "$WORK/password"; printf '\n'; } |
    guest_ssh_in 'sudo -S -k journalctl -b --no-pager -o short-iso' >"$GUEST_DIR/journal.txt" 2>"$GUEST_DIR/journal.err" || true
  grep -iE 'sudo' "$GUEST_DIR/journal.txt" >"$GUEST_DIR/journal-sudo.txt" || true
  guest_ssh 'cat /var/log/apt/history.log' >"$GUEST_DIR/apt-history.log" 2>&1 || true
}

# Whether dpkg and PATH both lack cosign in the guest.
guest_cosign_absent() {
  guest_ssh '! command -v cosign >/dev/null && ! dpkg-query -W -f "\${db:Status-Abbrev}" cosign 2>/dev/null | grep -q "^ii"'
}

# part_verdict PART: the part's verdict in OUT/results.txt; 1 when a check failed.
part_verdict() {
  if [ "$CHECK_FAILURES" -eq 0 ]; then
    printf '%s: passed\n' "$1" | tee -a "$OUT/results.txt"
    return 0
  fi
  printf '%s: failed, %s checks (%s)\n' "$1" "$CHECK_FAILURES" "$GUEST_DIR/results.txt" | tee -a "$OUT/results.txt"
  return 1
}

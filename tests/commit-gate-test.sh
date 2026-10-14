#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/commit-gate.sh against a recording stand-in for Mix: every Mix
# call passes at once unless the case names it to stall or hold, and each
# call's environment, directory and arguments are recorded. Everything else
# the gate runs is real: the JavaScript suite, the Python checks, test.yml's
# step scripts, the wasm-tools install and the partition runner. So the
# test takes the whole host (scripts/heavy-check.sh without -s).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
gate="$root/scripts/commit-gate.sh"
scratch=$(mktemp -d /tmp/cyfr-gate-test.XXXXXX)
. "$root/scripts/lib/contain.sh"
# Every gate this test starts leads a session of its own, so stopping
# them all stops what each started; a gate that ignores the stop is killed,
# and its legs' watchdogs stop the legs.
cleanup() {
  contain_stop_all 60 >/dev/null 2>&1 || :
  if [ -f "$scratch/registry-e" ]; then
    CONTAIN_REGISTRY="$scratch/registry-e" contain_sweep_registry 30 >/dev/null 2>&1 || :
  fi
  chmod -R u+w "$scratch" 2>/dev/null || :
  rm -rf "$scratch"
}
trap cleanup EXIT
# The gate's own environment is what each case gives it: an exporting
# shell would otherwise change the build-path assertions.
unset GATE_STEP_DEADLINE MIX_TEST_PARTITION MIX_ENV CYFR_DATABASE MIX_BUILD_PATH
fail() { echo "FAIL: $*" >&2; exit 1; }
# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0; shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
alive() {
  local s
  kill -0 "$1" 2>/dev/null || return 1
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  s=${s//[[:space:]]/}
  case $s in ''|Z*) return 1 ;; esac
}
dead() { ! alive "$1"; }
all_dead() { local p; for p in "$@"; do dead "$p" || return 1; done; }
sessions_empty() { local p; for p in "$@"; do ! pgrep -s "$p" >/dev/null || return 1; done; }
has_line() { grep -qE -- "$1" "$2"; }
no_line() { ! grep -qE -- "$1" "$2"; }
first_line() { head -n 1 "$1"; }
last_line() { tail -n 1 "$1"; }

mkdir -p "$scratch/bin"
cat > "$scratch/bin/mix" <<'FAKE'
#!/usr/bin/env bash
# Stands in for Mix. Each call appends one record to $TRACE/mix.calls:
#   MIX_ENV|CYFR_DATABASE|MIX_BUILD_PATH|MIX_TEST_PARTITION|directory|arguments
# with `-` for an unset variable. A call is named by its key: in an island
# copy `island_<app>_<task>`, elsewhere `<database>_<env>_<task>`. A key in
# STUB_STALL stalls with a grandchild; in STUB_SLOW_STOP it stalls and
# takes eight seconds to exit on TERM; in STUB_HOLD it waits for
# $TRACE/release; in STUB_DELAY it takes ten seconds. Each writes its pid
# (and the grandchild's) to $TRACE first.
printf '%s|%s|%s|%s|%s|%s\n' "${MIX_ENV:--}" "${CYFR_DATABASE:--}" "${MIX_BUILD_PATH:--}" "${MIX_TEST_PARTITION:--}" "$PWD" "$*" >> "$TRACE/mix.calls"
case "$PWD" in
  */island_*/apps/*) app=${PWD##*/}; key="island_${app}_$1"
    [ "${MIX_OS_CONCURRENCY_LOCK:-}" = 0 ] || echo "$PWD $1" >> "$TRACE/island-with-build-lock" ;;
  *) key="${CYFR_DATABASE:-none}_${MIX_ENV:-dev}_$1" ;;
esac
# The runner's assignment, as T03's tests stand in for it: `mix run
# --no-start --no-compile HELPER assign DIR COUNT TABLE REQUIRED FAILED --
# NAMES...` writes DIR/assign/p1..pCOUNT, each the partition's units,
# NUL-terminated, dealing the named paths round robin, or one unit to
# every partition when none is named.
if [ "$1" = run ] && [ "${5:-}" = assign ]; then
  dir=$6 count=$7
  shift 11
  if [ "$#" -eq 0 ]; then for ((p=1; p<=count; p++)); do set -- "$@" "stub_${p}_test.exs"; done; fi
  mkdir -p "$dir/assign"
  for ((p=1; p<=count; p++)); do : > "$dir/assign/p$p"; done
  p=0
  for unit in "$@"; do printf '%s\0' "$unit" >> "$dir/assign/p$((p % count + 1))"; p=$((p + 1)); done
  exit 0
fi
case " ${STUB_STALL:-} " in *" $key "*)
  sleep 300 & echo "$!" > "$TRACE/grandchild.$key"
  echo "$$" > "$TRACE/stalled.$key"
  wait ;;
esac
case " ${STUB_SLOW_STOP:-} " in *" $key "*)
  trap 'sleep 8; exit 143' TERM
  echo "$$" > "$TRACE/stalled.$key"
  while :; do sleep 1; done ;;
esac
case " ${STUB_HOLD:-} " in *" $key "*)
  echo "$$" > "$TRACE/held.$key"
  n=0
  until [ -e "$TRACE/release" ] || [ "$n" -ge 600 ]; do sleep 0.1; n=$((n + 1)); done ;;
esac
case " ${STUB_DELAY:-} " in *" $key "*) sleep 10 ;; esac
case "$1" in
  run)
    case "${!#}" in
      create) cat "$CYFR_TEST_RUN_ROOT/database-name" > "$CYFR_TEST_RUN_ROOT/database-created" ;;
      drop) rm "$CYFR_TEST_RUN_ROOT/database-created" ;;
    esac ;;
  test) echo 'Result: 1 passed' ;;
esac
exit 0
FAKE
chmod +x "$scratch/bin/mix"

# start_gate NAME [VAR=value...] -- GATE ARGS...: starts the gate as every
# harness test starts a wrapper (C1), as the leader of a session of its
# own, with SIGINT and SIGHUP at their defaults (an asynchronous command
# starts with SIGINT ignored, a caller may have HUP ignored, and a shell
# cannot trap a signal ignored at its start). Its
# stdout and stderr go to $scratch/NAME.out and .err, its trace to
# $scratch/NAME.trace, and its pid to $gate_pid.
start_gate() {
  local name=$1 vars=()
  shift
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  mkdir -p "$scratch/$name.trace"
  contain_start -g 60 perl -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV or die "exec $ARGV[0]: $!\n"' \
    env -u HEAVY_CHECK_HELD -u CONTAIN_REGISTRY -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS \
    TRACE="$scratch/$name.trace" PATH="$scratch/bin:$PATH" CYFR_DATABASE_URL='postgres://u:p@host/base' \
    ${vars[@]+"${vars[@]}"} bash "$@" >"$scratch/$name.out" 2>"$scratch/$name.err" </dev/null
  gate_pid=$CONTAIN_PID
}
# The status the gate exits with, once it has, in $gate_rc. Both run in
# this shell: a gate is this shell's child, and only this shell can reap it.
gate_status() { gate_rc=0; contain_wait "$1" 600 60 || gate_rc=$?; }
run_gate() { start_gate "$@"; gate_status "$gate_pid"; }
no_mix_ran() { [ ! -e "$scratch/$1.trace/mix.calls" ]; }
framed() {
  [ "$(first_line "$scratch/$1.out")" = "_START=$2" ] || fail "$1: the first stdout line is not _START=$2: $(first_line "$scratch/$1.out")"
  [ "$(last_line "$scratch/$1.out")" = "_EXIT=$2 $3" ] || fail "$1: the last stdout line is not _EXIT=$2 $3: $(last_line "$scratch/$1.out")"
  [ "$(grep -c '^_START=' "$scratch/$1.out")" = 1 ] && [ "$(grep -c '^_EXIT=' "$scratch/$1.out")" = 1 ] ||
    fail "$1: a terminal line that is not the gate's own: $(grep -E '^_(START|EXIT)=' "$scratch/$1.out" | tr '\n' ' ')"
}

# --- scoped refusal ----------------------------------------------------------
run_gate scoped HEAVY_CHECK_HELD=scoped -- "$gate" -l "$scratch/scoped.log"; [ "$gate_rc" = 64 ] || fail 'the gate ran as a scoped check'
no_line '^_(START|EXIT)=' "$scratch/scoped.out" || fail 'a refused scoped gate wrote a terminal line under heavy-check'
[ ! -e "$scratch/scoped.log" ] || fail 'a refused scoped gate touched its log directory'
no_mix_ran scoped || fail 'a refused scoped gate ran Mix'
echo 'ok: scoped refusal'

# --- step deadlines the containment library cannot take ------------------------
# Zero, and seven digits where contain_wait takes six: refused with 64
# before the log directory, the install or any leg.
for spec in zero:0 long:1234567; do
  name=${spec%%:*}
  run_gate "deadline-$name" GATE_STEP_DEADLINE="${spec#*:}" -- "$gate" -l "$scratch/deadline-$name.log"
  [ "$gate_rc" = 64 ] || fail "the gate accepted the step deadline ${spec#*:}: $gate_rc"
  framed "deadline-$name" "$gate_pid" 64
  has_line 'GATE_STEP_DEADLINE must be' "$scratch/deadline-$name.err" || fail "the step deadline ${spec#*:} was refused without its reason"
  [ ! -e "$scratch/deadline-$name.log" ] || fail "a refused step deadline ${spec#*:} made its log directory"
  no_mix_ran "deadline-$name" || fail "a refused step deadline ${spec#*:} started a leg"
done
# Six digits pass the deadline guard: a regular file as the log directory
# is then what refuses the gate, with its own reason.
echo text > "$scratch/deadline-six.file"
run_gate deadline-six GATE_STEP_DEADLINE=999999 -- "$gate" -l "$scratch/deadline-six.file"
[ "$gate_rc" = 64 ] || fail "a six-digit step deadline with a file as the log directory exited $gate_rc"
framed deadline-six "$gate_pid" 64
no_line 'GATE_STEP_DEADLINE' "$scratch/deadline-six.err" || fail "the six-digit step deadline 999999 was refused: $(cat "$scratch/deadline-six.err")"
has_line 'the log directory .* is not a directory' "$scratch/deadline-six.err" || fail "a six-digit step deadline did not reach the log directory check: $(cat "$scratch/deadline-six.err")"
echo 'ok: step deadlines out of range, and six digits accepted'

# --- the log directory ---------------------------------------------------------
echo text > "$scratch/a-file"
mkdir -p "$scratch/used" "$scratch/locked" "$scratch/sealed"
echo earlier > "$scratch/used/static.summary"
chmod 555 "$scratch/locked" "$scratch/sealed"
for spec in "file:$scratch/a-file:is not a directory" "used:$scratch/used:is not empty" \
  "locked:$scratch/locked/logs:cannot be created" "sealed:$scratch/sealed:is not writable"; do
  name=${spec%%:*}; rest=${spec#*:}; dir=${rest%%:*}; reason=${rest#*:}
  mkdir -p "$scratch/tmp-$name"
  run_gate "l-$name" TMPDIR="$scratch/tmp-$name" -- "$gate" -l "$dir"; [ "$gate_rc" = 64 ] || fail "-l naming $dir was not refused with 64"
  framed "l-$name" "$gate_pid" 64
  has_line "the log directory .* $reason" "$scratch/l-$name.err" || fail "-l naming $dir was refused without its reason: $(cat "$scratch/l-$name.err")"
  no_mix_ran "l-$name" || fail "-l naming $dir started a leg"
  [ -z "$(ls -A "$scratch/tmp-$name")" ] || fail "a refused -l left files in TMPDIR: $(ls -A "$scratch/tmp-$name")"
done
[ "$(ls -A "$scratch/used")" = static.summary ] && [ "$(cat "$scratch/used/static.summary")" = earlier ] ||
  fail "a refused -l changed the used directory: $(ls -A "$scratch/used")"
[ ! -e "$scratch/locked/logs" ] || fail 'a refused -l created a directory'
[ -z "$(ls -A "$scratch/sealed")" ] || fail 'a refused -l wrote into an unwritable directory'
echo 'ok: the log directory'

# --- a start the containment library refuses -------------------------------------
run_gate fdbase CONTAIN_FD_BASE=x -- "$gate" -l "$scratch/fdbase.log"; [ "$gate_rc" = 64 ] || fail 'a refused start (descriptor base) did not end the gate with 64'
framed fdbase "$gate_pid" 64
has_line 'CONTAIN_FD_BASE' "$scratch/fdbase.err" || fail "a refused start gave no reason: $(cat "$scratch/fdbase.err")"
no_mix_ran fdbase || fail 'a refused start went on to the legs'
# Every program on PATH but setsid and perl.
mkdir -p "$scratch/nosetsid"
IFS=: read -r -a path_dirs <<<"$scratch/bin:$PATH"
for d in "${path_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}
    case $b in setsid|perl|perl5*) continue ;; esac
    [ -x "$f" ] && [ ! -e "$scratch/nosetsid/$b" ] && ln -s "$f" "$scratch/nosetsid/$b"
  done
done
run_gate nosetsid PATH="$scratch/nosetsid" -- "$gate" -l "$scratch/nosetsid.log"; [ "$gate_rc" = 69 ] || fail 'a gate without setsid or perl did not exit 69'
framed nosetsid "$gate_pid" 69
has_line 'needs setsid' "$scratch/nosetsid.err" || fail "a gate without setsid or perl gave no reason: $(cat "$scratch/nosetsid.err")"
no_mix_ran nosetsid || fail 'a gate without setsid or perl went on to the legs'
echo 'ok: a refused start'

# --- a leg run alone ----------------------------------------------------------------
# start_leg NAME LEG [VAR=value...]: the leg as the gate starts it, with a
# fresh log directory and the gate's options in its environment.
start_leg() {
  local name=$1 leg=$2
  shift 2
  mkdir -p "$scratch/$name.log"
  start_gate "$name" GATE_LEG_LOGDIR="$scratch/$name.log" GATE_LEG_PARTS=2 GATE_LEG_CLOSE=false "$@" -- "$gate" --leg "$leg"
}
# A selection git cannot read fails the postgres leg after its compile,
# with its marker, and no test runs.
start_leg pgread postgres GIT_DIR=/nonexistent
gate_status "$gate_pid"
[ "$gate_rc" = 1 ] || fail "a postgres leg whose selection could not be read exited $gate_rc"
[ "$(tr '\n' ' ' < "$scratch/pgread.log/postgres.summary")" = 'compile_pg_test=0 pg_selection_read=1 ' ] ||
  fail "an unreadable selection was not recorded: $(tr '\n' ' ' < "$scratch/pgread.log/postgres.summary")"
[ -e "$scratch/pgread.log/postgres.done" ] || fail 'the postgres leg left no marker after an unreadable selection'
[ "$(awk -F'|' '{ print $6 }' "$scratch/pgread.trace/mix.calls")" = 'compile --force --warnings-as-errors' ] ||
  fail "the postgres leg ran more than its compile: $(tr '\n' ' ' < "$scratch/pgread.trace/mix.calls")"
no_line '^_(START|EXIT)=' "$scratch/pgread.out" || fail 'a leg wrote a terminal line'
# An island phase the containment library refuses ends the leg with the
# refusal, as a refused step does: 64 on a bad descriptor base, 69 with
# neither setsid nor perl. The static leg's marker is there, so the
# islands start at once.
for spec in fd64:64:CONTAIN_FD_BASE=x "path69:69:PATH=$scratch/nosetsid"; do
  name=${spec%%:*}; rest=${spec#*:}; want=${rest%%:*}
  mkdir -p "$scratch/$name.log"
  : > "$scratch/$name.log/static.done"
  start_leg "$name" islands "${rest#*:}"
  gate_status "$gate_pid"
  [ "$gate_rc" = "$want" ] || fail "an islands leg whose phase was refused with $want exited $gate_rc: $(cat "$scratch/$name.err")"
  for isl in prima arca sanctum; do
    has_line "^${isl}_refused=$want\$" "$scratch/$name.log/islands.summary" || fail "the refused $isl island was not recorded: $(tr '\n' ' ' < "$scratch/$name.log/islands.summary")"
  done
  [ -e "$scratch/$name.log/islands.done" ] || fail 'the islands leg left no marker after a refused phase'
  [ -z "$(find "$scratch/$name.log" -maxdepth 1 -name 'island_*')" ] || fail "a refused island's copy was left behind"
  no_mix_ran "$name" || fail 'a refused island phase ran Mix'
done
echo 'ok: a leg run alone: an unreadable selection, refused island phases'

# --- a whole gate whose island phases are refused ---------------------------------
# The refusal reaches the islands leg alone: bash sources BASH_ENV with the
# script's own arguments, so only `--leg islands` takes the bad descriptor
# base or the PATH without setsid and perl, while the install, the other
# legs and their steps start as usual. The gate exits with the refusal,
# through its mapping of each leg's status.
for spec in fd64:64:'CONTAIN_FD_BASE=x' "path69:69:PATH='$scratch/nosetsid'"; do
  name=${spec%%:*}; rest=${spec#*:}; want=${rest%%:*}
  printf 'case "${1:-}:${2:-}" in --leg:islands) %s ;; esac\n' "${rest#*:}" > "$scratch/$name.bash_env"
  run_gate "whole-$name" BASH_ENV="$scratch/$name.bash_env" -- "$gate" -n 2 -l "$scratch/whole-$name.log"
  [ "$gate_rc" = "$want" ] || fail "a gate whose island phases were refused with $want exited $gate_rc: $(cat "$scratch/whole-$name.err")"
  framed "whole-$name" "$gate_pid" "$want"
  for leg in static postgres vocab; do
    has_line "^==> $leg +ok " "$scratch/whole-$name.out" || fail "the $leg leg did not pass beside refused islands: $(cat "$scratch/whole-$name.out")"
  done
  has_line "^==> islands +FAILED .*prima_refused=$want" "$scratch/whole-$name.out" || fail "the refused islands were not reported: $(cat "$scratch/whole-$name.out")"
  no_line '/island_' "$scratch/whole-$name.trace/mix.calls" || fail 'a refused island phase ran Mix'
done
echo 'ok: a whole gate whose island phases are refused exits with the refusal'

# --- the PostgreSQL selection ----------------------------------------------------
selection() { (cd "$1" && . "$gate" && pg_selection); }
selection "$root" > "$scratch/selection.txt" || fail 'the selection failed on the tree'
[ "$(head -n 2 "$scratch/selection.txt" | tr '\n' ' ')" = 'apps/arca/test apps/cyfr/test/arca ' ] || fail 'the selection does not start with the storage set'
[ -z "$(sort "$scratch/selection.txt" | uniq -d)" ] || fail "the selection names a path twice: $(sort "$scratch/selection.txt" | uniq -d | tr '\n' ' ')"
no_line '^apps/(arca/test|cyfr/test/arca)/' "$scratch/selection.txt" || fail 'the selection names a file the storage set already holds'
for f in \
  apps/cyfr/test/cyfr_web/plugs/verify_webhook_signature_test.exs \
  apps/cyfr/test/emissary/web/controllers/execution_events_controller_test.exs \
  apps/cyfr/test/aqua/runner_test.exs \
  apps/cyfr/test/cyfr/runtime_config_wiring_test.exs \
  apps/cyfr/test/opus/provider_test.exs \
  apps/cyfr/test/sanctum/credential_retirement_test.exs \
  apps/cyfr/test/opus/feeds_test.exs \
  apps/cyfr/test/sanctum/consent/commit_test.exs \
  apps/cyfr/test/sanctum/tenancy/members_test.exs \
  apps/sanctum/test/sanctum/webhook_entries_test.exs \
  apps/sanctum/test/sanctum/issuance_test.exs \
  apps/sanctum/test/sanctum/validation_credential_test.exs \
  apps/sanctum/test/sanctum/consent/authz_test.exs \
  apps/cyfr/test/aqua/loop/flush_test.exs; do
  [ -f "$root/$f" ] || fail "a listed adapter-branching file is gone: $f"
  grep -qxF "$f" "$scratch/selection.txt" || fail "the selection misses $f"
done
no_line '^apps/cyfr/test/cyfr/cell_test.exs$' "$scratch/selection.txt" || fail 'the selection holds cell_test.exs, which does not branch'
# Planted in a repository of their own: git grep reads tracked files only.
plant="$scratch/plant"
mkdir -p "$plant/apps/x/test/support" "$plant/apps/x/lib" "$plant/apps/arca/test"
git -C "$plant" init -q
printf 'test "a" do\n  if Arca.Test.Adapter.postgres?() do :pg else :lite end\nend\n' > "$plant/apps/x/test/branch_test.exs"
printf '@tag :sqlite\ntest "b", do: :ok\n' > "$plant/apps/x/test/tagged_test.exs"
printf 'test "c", do: assert 1 == 1\n' > "$plant/apps/x/test/plain_test.exs"
printf 'test "d", do: my_postgres?()\n' > "$plant/apps/x/test/lookalike_test.exs"
printf '@tag :postgres\n' > "$plant/apps/arca/test/stored_test.exs"
printf '@tag :postgres\n' > "$plant/apps/x/test/support/case.ex"
printf '@tag :postgres\n' > "$plant/apps/x/lib/thing_test.exs"
git -C "$plant" add apps
printf '@tag :postgres\n' > "$plant/apps/x/test/untracked_test.exs"
selection "$plant" > "$scratch/plant.txt" || fail 'the selection failed on the planted repository'
[ "$(tr '\n' ' ' < "$scratch/plant.txt")" = 'apps/arca/test apps/cyfr/test/arca apps/x/test/branch_test.exs apps/x/test/tagged_test.exs ' ] ||
  fail "the planted selection is wrong: $(tr '\n' ' ' < "$scratch/plant.txt")"
echo 'ok: the PostgreSQL selection'

# --- a whole gate that passes ------------------------------------------------------
run_gate pass -- "$gate" -n 2 -l "$scratch/pass.log"
[ "$gate_rc" = 0 ] || fail "a gate whose every step passes exited $gate_rc: $(cat "$scratch/pass.err")"
framed pass "$gate_pid" 0
has_line '^==> gate passed in ' "$scratch/pass.out" || fail "a passing gate did not report its verdict: $(cat "$scratch/pass.out")"
# Every suite the gate runs reported a result, so a gate whose partitions
# ran nothing cannot pass here.
for suite in static.sqlite_suite postgres.pg_tests islands.prima islands.arca islands.sanctum; do
  has_line "^    ${suite//./\\.}: .*Result: " "$scratch/pass.out" || fail "the passing gate's $suite reported no result: $(cat "$scratch/pass.out")"
done
echo 'ok: a whole gate that passes, every suite with a result'

# --- a whole gate: a stalled island, build paths, the pg leg, the framing --------
# Started by a relative path from another directory; the caller's build
# path is the PostgreSQL one. The arca island's tests stall with a
# grandchild and reach their deadline; the sanctum island's compile takes
# ten seconds and its tests hold, so the gate still runs when arca is
# stopped.
mkdir -p "$scratch/tmp-a"
cd "$root/scripts"
start_gate a TMPDIR="$scratch/tmp-a" MIX_BUILD_PATH=_build/test_pg GATE_STEP_DEADLINE=20 \
  STUB_STALL=island_arca_test STUB_DELAY=island_sanctum_compile STUB_HOLD=island_sanctum_test \
  -- ./commit-gate.sh -n 3 -l "$scratch/a.log"
cd "$root"
a=$gate_pid
trace="$scratch/a.trace"
until_true 120 test -s "$trace/grandchild.island_arca_test" || fail "the arca island never stalled: $(cat "$scratch/a.err")"
grandchild=$(cat "$trace/grandchild.island_arca_test")
until_true 5 test -s "$trace/stalled.island_arca_test" || fail 'the stalled step did not record its pid'
stalled=$(cat "$trace/stalled.island_arca_test")
alive "$grandchild" || fail "the stalled step's grandchild was not running before the deadline"
alive "$stalled" || fail 'the stalled step was not running before its deadline'
until_true 60 has_line '^arca=124$' "$scratch/a.log/islands.summary" || fail 'the stalled island was not recorded at its deadline'
dead "$grandchild" || fail "the stalled step's grandchild survived its deadline"
dead "$stalled" || fail 'the stalled step survived its deadline'
alive "$a" || fail 'the gate had ended before the stalled step was checked'
no_line '^_EXIT=' "$scratch/a.out" || fail 'the gate had written its exit line before the stalled step was checked'
touch "$trace/release"
gate_status "$a"; [ "$gate_rc" = 1 ] || fail "a gate with a stalled island did not exit 1: $(cat "$scratch/a.err")"
framed a "$a" 1
has_line '^prima=0$' "$scratch/a.log/islands.summary" || fail 'the prima island did not pass beside the stalled one'
has_line '^sanctum=0$' "$scratch/a.log/islands.summary" || fail 'the sanctum island did not pass beside the stalled one'
has_line '^==> islands.arca stopped at its deadline$' "$scratch/a.err" || fail 'the stalled island was not reported'
for s in compile_sqlite_test compile_sqlite_dev js_suite sdk_bundle toolkit_bundle canary_checks worker_auth_check backends_check dialyzer boundary_plants sqlite_suite; do
  has_line "^$s=0$" "$scratch/a.log/static.summary" || fail "the static step $s did not pass: $(tr '\n' ' ' < "$scratch/a.log/static.summary")"
done
has_line '^pg_tests=0$' "$scratch/a.log/postgres.summary" || fail "the PostgreSQL tests did not pass: $(tr '\n' ' ' < "$scratch/a.log/postgres.summary")"
has_line '^fossils=0$' "$scratch/a.log/vocab.summary" || fail 'the vocabulary leg did not pass'
has_line '^==> islands +FAILED ' "$scratch/a.out" || fail 'the islands leg was not reported failed'
has_line '^==> static +ok .*worker_auth_check=0 backends_check=0 ' "$scratch/a.out" || fail 'the static leg and its Python self-checks were not reported passed'
has_line '^==> postgres +ok ' "$scratch/a.out" || fail 'the postgres leg was not reported passed'
has_line '^    postgres\.pg_tests: Result: 1 passed' "$scratch/a.out" || fail 'the final report did not read the PostgreSQL tests'
[ -z "$(find "$scratch/a.log" -maxdepth 1 -name 'island_*')" ] || fail "the stalled island's copy was left behind"
[ ! -e "$trace/island-with-build-lock" ] || fail "an island's Mix ran with its build lock on: $(tr '\n' ' ' < "$trace/island-with-build-lock")"
[ -z "$(ls -A "$scratch/tmp-a")" ] || fail "a direct gate left files in TMPDIR: $(ls -A "$scratch/tmp-a")"
echo 'ok: a stalled island at its deadline, its grandchild, the framing, the registry'

# The PostgreSQL selection the leg ran.
n=$(sed -n 's/^pg_selection=//p' "$scratch/a.log/postgres.summary")
[ -n "$n" ] && [ "$n" = "$(wc -l < "$scratch/a.log/postgres.pg_selection.txt" | tr -d ' ')" ] ||
  fail "pg_selection=$n does not count postgres.pg_selection.txt"
cmp -s "$scratch/a.log/postgres.pg_selection.txt" "$scratch/selection.txt" || fail 'the postgres leg did not run the selection'
has_line "^    postgres\.pg_selection: $n paths handed to the runner, listed in postgres\.pg_selection\.txt\$" "$scratch/a.out" ||
  fail 'the final report did not say what pg_selection counts'
calls="$trace/mix.calls"
# MIX_ENV|CYFR_DATABASE|MIX_BUILD_PATH|MIX_TEST_PARTITION|directory|arguments
# A partition's test run: `mix test` with MIX_TEST_PARTITION set, from the
# checkout. Read by partition, so the check holds however the runner hands
# each partition its files.
partition_runs() { awk -F'|' -v db="$2" -v dir="$root" '$1 == "test" && $2 == db && $4 != "-" && $5 == dir && $6 ~ /^test /' "$1"; }
partitions_of() { partition_runs "$1" "$2" | awk -F'|' '{ print $4 }' | sort -n | tr '\n' ' '; }
pg_runs=$(partition_runs "$calls" postgres)
[ -n "$pg_runs" ] || fail 'the postgres leg ran no tests'
[ "$(partitions_of "$calls" postgres)" = '1 2 ' ] || fail "the postgres leg's runner did not run two partitions: $pg_runs"
printf '%s\n' "$pg_runs" | grep -qF -- ' apps/cyfr/test/sanctum/consent/commit_test.exs' || fail 'the postgres leg did not pass the selection to Mix'
[ "$(partitions_of "$calls" sqlite)" = '1 2 3 ' ] || fail "the SQLite suite did not run the partitions the gate was given: $(partition_runs "$calls" sqlite)"
build_path() { # PATTERN EXPECTED: every call matching PATTERN had EXPECTED as its build path
  local lines
  lines=$(grep -E -- "$1" "$calls" || :)
  [ -n "$lines" ] || fail "no Mix call matched $1"
  [ -z "$(printf '%s\n' "$lines" | awk -F'|' -v want="$2" '$3 != want')" ] || fail "a Mix call matching $1 did not have the build path $2: $lines"
}
build_path "^test\|sqlite\|[^|]*\|-\|$root\|compile --force" _build/test
build_path "^test\|sqlite\|[^|]*\|-\|$root\|test apps/cyfr/test/cyfr/boundaries_test.exs --only boundary_plant" _build/test
build_path '^test\|sqlite\|[^|]*\|[0-9]+\|[^|]*\|test ' _build/test
build_path '^test\|sqlite\|[^|]*\|[^|]*\|[^|]*\|esbuild ' _build/test
build_path "^dev\|sqlite\|[^|]*\|-\|$root\|compile --force" -
build_path "^-\|-\|[^|]*\|-\|$root\|(format|credo|ops.gen.cli|cyfr.gen.configuration_guide|dialyzer)" -
build_path '^test\|postgres\|' _build/test_pg
build_path '^[^|]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*/island_[^|]*\|' -
echo 'ok: inherited build paths, the pg selection and its two partitions'

# --- TERM: the gate stops its legs, each leg its steps, an island its own --------
start_gate term STUB_SLOW_STOP=island_arca_test -- "$gate" -n 2 -l "$scratch/term.log"
t=$gate_pid
until_true 120 test -s "$scratch/term.trace/stalled.island_arca_test" || fail "the TERM case's island never stalled: $(cat "$scratch/term.err")"
stalled=$(cat "$scratch/term.trace/stalled.island_arca_test")
alive "$stalled" || fail 'the stalled island step was not running before the TERM'
legs=$(pgrep -P "$t" | tr '\n' ' ')
[ -n "$legs" ] || fail 'the TERM case found no leg to watch'
kill -TERM "$t"
until_true 60 has_line '^_EXIT=' "$scratch/term.out" || fail 'a gate given TERM wrote no exit line'
dead "$stalled" || fail "the stalled island step outlived the gate's exit line"
# shellcheck disable=SC2086
all_dead $legs || fail 'a leg outlived the gate'
gate_status "$t"; [ "$gate_rc" = 143 ] || fail 'a gate given TERM did not exit 143'
framed term "$t" 143
[ -z "$(find "$scratch/term.log" -maxdepth 1 -name 'island_*')" ] || fail "a stopped island's copy was left behind: the leg did not stop its islands before it exited"
echo 'ok: TERM'

# --- INT ---------------------------------------------------------------------------
start_gate int STUB_HOLD=sqlite_test_compile -- "$gate" -n 2 -l "$scratch/int.log"
i=$gate_pid
until_true 60 test -s "$scratch/int.trace/held.sqlite_test_compile" || fail "the INT case's step never started: $(cat "$scratch/int.err")"
held=$(cat "$scratch/int.trace/held.sqlite_test_compile")
alive "$held" || fail 'the held step was not running before the INT'
kill -INT "$i"
gate_status "$i"; [ "$gate_rc" = 130 ] || fail 'a gate given INT did not exit 130'
framed int "$i" 130
dead "$held" || fail 'a step outlived a gate given INT'
echo 'ok: INT'

# --- HUP, and a signal the gate does not trap --------------------------------------
# HUP stops the gate as TERM does, with 129. USR1 is not trapped: Bash runs
# the EXIT trap with $? at 0 and then dies of it, and the exit line must
# still not say 0.
for spec in hup:HUP:129:129 usr1:USR1:1:138; do
  IFS=: read -r name sig line want <<<"$spec"
  start_gate "$name" STUB_HOLD=sqlite_test_compile -- "$gate" -n 2 -l "$scratch/$name.log"
  p=$gate_pid
  until_true 60 test -s "$scratch/$name.trace/held.sqlite_test_compile" || fail "the $sig case's step never started: $(cat "$scratch/$name.err")"
  held=$(cat "$scratch/$name.trace/held.sqlite_test_compile")
  alive "$held" || fail "the held step was not running before the $sig"
  kill -"$sig" "$p"
  gate_status "$p"; [ "$gate_rc" = "$want" ] || fail "a gate given $sig exited $gate_rc, not $want"
  framed "$name" "$p" "$line"
  dead "$held" || fail "a step outlived a gate given $sig"
done
echo 'ok: HUP, and an untrapped USR1 not reported as success'

# --- SIGKILL: the watchdogs stop every leg and step ------------------------------
start_gate kill STUB_HOLD='sqlite_test_compile postgres_test_compile' -- "$gate" -n 2 -l "$scratch/kill.log"
k=$gate_pid
until_true 60 test -s "$scratch/kill.trace/held.sqlite_test_compile" || fail "the SIGKILL case's static step never started: $(cat "$scratch/kill.err")"
until_true 60 test -s "$scratch/kill.trace/held.postgres_test_compile" || fail "the SIGKILL case's postgres step never started: $(cat "$scratch/kill.err")"
steps="$(cat "$scratch/kill.trace/held.sqlite_test_compile") $(cat "$scratch/kill.trace/held.postgres_test_compile")"
legs=$(pgrep -P "$k" | tr '\n' ' ')
[ -n "$legs" ] || fail 'the SIGKILL case found no leg to watch'
# shellcheck disable=SC2086
alive_all() { local p; for p in "$@"; do alive "$p" || return 1; done; }
# shellcheck disable=SC2086
alive_all $steps || fail 'the held steps were not running before the SIGKILL'
kill -KILL "$k"
# Its legs and steps answer TERM at once, so their watchdogs end them in
# seconds, far inside the leg grace.
# shellcheck disable=SC2086
until_true 30 all_dead $legs $steps || fail "a leg or step outlived a SIGKILLed gate: $(for p in $legs $steps; do alive "$p" && echo "$p"; done | tr '\n' ' ')"
# shellcheck disable=SC2086
until_true 15 sessions_empty $legs $steps || fail 'a session of a SIGKILLed gate kept a process'
gate_status "$k"; [ "$gate_rc" = 137 ] || fail 'the SIGKILLed gate was not reaped'
echo 'ok: SIGKILL'

# --- a leg that dies without its marker; under heavy-check; explicit paths -------
# Run as heavy-check runs it: no terminal lines, and its sessions recorded
# in the registry heavy-check owns, which it leaves in place.
( umask 077 && : > "$scratch/registry-e" )
start_gate e HEAVY_CHECK_HELD=exclusive CONTAIN_REGISTRY="$scratch/registry-e" STUB_HOLD=sqlite_test_compile \
  -- "$gate" -n 2 -l "$scratch/e.log" -- apps/arca/test apps/sanctum/test/sanctum/issuance_test.exs
e=$gate_pid
until_true 60 test -s "$scratch/e.trace/held.sqlite_test_compile" || fail "the dead-leg case's step never started: $(cat "$scratch/e.err")"
static_leg=$(pgrep -P "$e" -f -- '--leg static' | head -n 1)
[ -n "$static_leg" ] && alive "$static_leg" || fail 'the static leg was not found running'
kill -KILL "$static_leg"
until_true 10 has_line '^await_static=1$' "$scratch/e.log/islands.summary" || fail 'the leg waiting on a dead leg did not fail within 10 s'
touch "$scratch/e.trace/release"
gate_status "$e"; [ "$gate_rc" = 1 ] || fail 'a gate whose leg died did not exit 1'
has_line '^==> static +FAILED' "$scratch/e.out" || fail 'the dead leg was not reported failed'
has_line '^==> islands +FAILED .*await_static=1' "$scratch/e.out" || fail 'the waiting leg was not reported failed'
[ ! -e "$scratch/e.log/static.done" ] || fail 'the dead leg left its marker'
no_line '^_(START|EXIT)=' "$scratch/e.out" || fail 'a gate under heavy-check wrote a terminal line'
[ -f "$scratch/registry-e" ] || fail "a nested gate removed heavy-check's registry"
grep -qxF "$static_leg" "$scratch/registry-e" || fail "a nested gate did not record its legs in heavy-check's registry"
[ "$(tr '\n' ' ' < "$scratch/e.log/postgres.pg_selection.txt")" = 'apps/arca/test apps/sanctum/test/sanctum/issuance_test.exs ' ] ||
  fail 'the given PostgreSQL paths did not replace the selection'
has_line '^pg_selection=2$' "$scratch/e.log/postgres.summary" || fail 'the given PostgreSQL paths were not counted'
has_line '^    postgres\.pg_selection: 2 paths handed to the runner' "$scratch/e.out" || fail 'the report did not count the given PostgreSQL paths'
pg_runs=$(partition_runs "$scratch/e.trace/mix.calls" postgres)
[ "$(partitions_of "$scratch/e.trace/mix.calls" postgres)" = '1 2 ' ] || fail "the given PostgreSQL paths did not run in two partitions: $pg_runs"
# Every path the partitions were given lies under the ones given, and
# each given path reached a partition.
pg_paths=$(printf '%s\n' "$pg_runs" | awk -F'|' '{ print $6 }' | tr ' ' '\n' | grep -E '^apps/' || :)
[ -z "$(printf '%s\n' "$pg_paths" | grep -vE '^(apps/arca/test(/|$)|apps/sanctum/test/sanctum/issuance_test\.exs$)')" ] ||
  fail "the postgres leg ran paths outside the given ones: $pg_runs"
printf '%s\n' "$pg_paths" | grep -qE '^apps/arca/test(/|$)' && printf '%s\n' "$pg_paths" | grep -qxF apps/sanctum/test/sanctum/issuance_test.exs ||
  fail "a given PostgreSQL path reached no partition: $pg_runs"
echo 'ok: a leg that dies without its marker, the terminal lines under heavy-check, given PostgreSQL paths'

echo 'commit gate tests passed'

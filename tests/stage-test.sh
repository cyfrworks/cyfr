#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/stage.sh against a toy repository with a toy table and a stand-in
# scripts/heavy-check.sh that records each call and runs its command (a
# command holding `#queue-deadline` is answered 75, as a queue deadline is,
# and a folder's ticket ends STUB_TICKET_EXIT after its chain when that is set)
# and a stand-in scripts/test-partitioned.sh that records each call;
# scripts/lib/nightly.py's flakes and weights on planted run directories;
# and the real table, read whole by the real scripts/stage.sh, each
# self-test its handoff runs held to a pull-request workflow that runs it
# too. It needs git, python3 with PyYAML, and no Docker, database or build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-stage-test.XXXXXX")
S=$(cd "$S" && pwd -P)
trap 'rm -rf "$S"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR HEAVY_CHECK_HELD STAGE_BASE PROOF_RUN_PREFIX
export GIT_CEILING_DIRECTORIES="$S" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0
  shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
# A signal ignored on entry cannot be trapped, and a command started in the
# background ignores INT unless it is reset first.
defaulted=(python3 -I -c 'import os, signal, sys; signal.signal(getattr(signal, "SIG" + sys.argv[1]), signal.SIG_DFL); os.execvp(sys.argv[2], sys.argv[2:])')

put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
# The toy table: one row per argument, its fields separated by |.
table() { printf '%s\n' "$@" | tr '|' '\t' >"$repo/scripts/stages.tsv"; }

repo="$S/repo"
git init -q -b main "$repo"
mkdir -p "$repo/scripts"
mkdir -p "$repo/scripts/lib"
cp "$ROOT/scripts/stage.sh" "$repo/scripts/"
cp "$ROOT/scripts/lib/stage-chain.sh" "$ROOT/scripts/lib/contain.sh" "$repo/scripts/lib/"
cat >"$repo/scripts/test-partitioned.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RUNNER_CALLS"
EOF
cat >"$repo/scripts/heavy-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$*" in *'#queue-deadline'*) exit 75 ;; esac
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
case "$*" in *stage-chain.sh*) [ -z "${STUB_TICKET_EXIT:-}" ] || { "$@"; exit "$STUB_TICKET_EXIT"; } ;; esac
exec "$@"
EOF
chmod +x "$repo/scripts/heavy-check.sh" "$repo/scripts/test-partitioned.sh"
export STUB_CALLS="$S/calls" RUNNER_CALLS="$S/runner-calls"
for f in apps/arca/lib/arca/x.ex apps/arca/test/arca/x_test.exs apps/cyfr/lib/cyfr/a.ex apps/cyfr/test/cyfr/a_test.exs \
  apps/cyfr/lib/cyfr/no_mirror.ex apps/cyfr/lib/cyfr/gone.ex apps/cyfr/test/cyfr/gone_test.exs apps/cyfr/test/cyfr/old_test.exs \
  apps/cyfr/lib/cluster/k.ex apps/cyfr/test/cluster/k_test.exs apps/cyfr/test/cluster/c_test.exs notes/today.md README.md; do
  put "$repo/$f" "$f"
done
toy_rows=(
  'handoff|format|1|60|-|always|git grep -q . -- README.md'
  'handoff|compile|1|60|-|apps/**,config/**|echo compile'
  'handoff|dialyzer|1|60|-|apps/*/lib/**|echo dialyzer'
  'handoff|arca|1|60|-|apps/arca/**|echo arca'
  'handoff|tests|1|60|-|tests|printf "%s\n" $STAGE_TESTS >"$STAGE_LOGDIR/tests.txt"'
  'handoff|env|4|60|-|always|printf "%s;%s;%s;%s\n" "$STAGE" "$STAGE_TESTS" "$STAGE_LOGDIR" "${PROOF_RUN_PREFIX-unset}" >"$STAGE_LOGDIR/env.txt"'
  'handoff|notes|4|60|-|notes/**|echo notes'
  'release|close|4|60|-|always|echo close'
)
table "${toy_rows[@]}"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m init

# Runs the toy repository's scripts/stage.sh: stage NAME ARGS...; its
# stdout goes to $S/NAME.out, stderr to $S/NAME.err, status to $rc.
stage() {
  local name=$1
  shift
  : >"$STUB_CALLS"
  rc=0
  (cd "$repo" && scripts/stage.sh "$@") >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
framed() { # NAME STATUS: the run's stdout is framed by its own pid
  local first last pid
  first=$(head -n 1 "$S/$1.out"); last=$(tail -n 1 "$S/$1.out")
  pid=${first#_START=}
  [[ $first =~ ^_START=[0-9]+$ ]] && [ "$last" = "_EXIT=$pid $2" ] || fail "$1 is not framed _START/_EXIT $2: $first ... $last"
}
reset_tree() { git -C "$repo" checkout -q -- . && git -C "$repo" clean -qfd -e scripts; }

begin 'every row of a stage runs or is skipped by its when, on its quarters, with the stage environment'
reset_tree
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
stage run -l "$S/logs-run" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/run.err")"
framed run 0
sed -n '2,$p' "$S/run.out" | sed '$d' | sed -E 's/ [0-9]+s$//' >"$S/got"
printf '%s\n' 'format: ok' 'compile: ok' 'dialyzer: ok' 'arca: skipped (no changed path matches apps/arca/**)' \
  'tests: ok' 'env: ok' 'notes: skipped (no changed path matches notes/**)' >"$S/want"
diff "$S/want" "$S/got" >/dev/null || fail "the rows said: $(tr '\n' ';' <"$S/got")"
[ "$(cat "$S/logs-run/tests.txt")" = apps/cyfr/test/cyfr/a_test.exs ] || fail "STAGE_TESTS: $(cat "$S/logs-run/tests.txt")"
[ "$(cat "$S/logs-run/env.txt")" = "handoff;apps/cyfr/test/cyfr/a_test.exs;$S/logs-run;unset" ] ||
  fail "the row environment: $(cat "$S/logs-run/env.txt")"
grep -qx 'compile' "$S/logs-run/compile.log" || fail 'a row log does not hold its output'
# A row queues with its hold alone: its wait for the host is heavy-check's
# default queue deadline, which tests/heavy-check-test.sh holds above every
# hold of the real table.
grep -qx -- '-q 1 -t 60 -- bash -c echo compile' "$STUB_CALLS" || fail "a row on one quarter did not queue -q 1 -t 60: $(cat "$STUB_CALLS")"
grep -qx -- '-q 1 -t 60 -- bash -c git grep -q . -- README.md' "$STUB_CALLS" || fail 'the format row did not queue -q 1'
grep -q -- '^-q 4 -t 60 -- bash -c printf' "$STUB_CALLS" || fail 'a row on four quarters did not queue -q 4'
grep -qF "stage: handoff logs in $S/logs-run" "$S/run.err" || fail 'the log directory is not named'

begin 'the changed set holds deleted paths for the rows, and the touched tests hold only tests that exist'
reset_tree
printf '# edit\n' >>"$repo/apps/cyfr/test/cyfr/a_test.exs"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/no_mirror.ex"
rm "$repo/apps/cyfr/lib/cyfr/gone.ex" "$repo/apps/cyfr/test/cyfr/old_test.exs"
printf '# edit\n' >>"$repo/apps/cyfr/test/cluster/c_test.exs"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cluster/k.ex"
printf '# edit\n' >>"$repo/apps/arca/lib/arca/x.ex"
stage planted -l "$S/logs-planted" handoff
[ "$rc" = 0 ] || fail "exited $rc"
printf '%s\n' apps/arca/test/arca/x_test.exs apps/cyfr/test/cyfr/a_test.exs apps/cyfr/test/cyfr/gone_test.exs >"$S/want"
diff "$S/want" "$S/logs-planted/tests.txt" >/dev/null || fail "the touched tests: $(tr '\n' ' ' <"$S/logs-planted/tests.txt")"
grep -qx 'arca: ok [0-9]*s' "$S/planted.out" || fail 'an Arca change did not select the Arca row'

begin 'a new file selects the rows its path matches, alone and beside an edited path the same glob matches'
reset_tree
put "$repo/notes/new.md" new
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
put "$repo/apps/cyfr/lib/cyfr/new.ex" new
stage untracked -n handoff
[ "$rc" = 0 ] || fail "exited $rc"
for check in compile dialyzer notes; do grep -q "^would run $check " "$S/untracked.out" || fail "$check would not run: $(cat "$S/untracked.out")"; done
reset_tree

begin 'a deleted lib file alone selects the compile, dialyzer and Arca rows and puts its mirror test, never itself, in the list'
reset_tree
rm "$repo/apps/arca/lib/arca/x.ex"
stage deleted -n handoff
[ "$rc" = 0 ] || fail "exited $rc"
for check in compile dialyzer arca tests; do grep -q "^would run $check " "$S/deleted.out" || fail "$check would not run"; done
grep -q '^would skip notes: ' "$S/deleted.out" || fail 'notes would run'
stage deleted-run -l "$S/logs-deleted" handoff
[ "$(cat "$S/logs-deleted/tests.txt")" = apps/arca/test/arca/x_test.exs ] || fail "the touched tests: $(cat "$S/logs-deleted/tests.txt")"
if grep -q 'lib/arca/x.ex' "$S/logs-deleted/tests.txt"; then fail 'the deleted file reached the test paths'; fi

begin 'a deleted test is absent from the list, and an empty change set skips every path and tests row while format runs'
reset_tree
rm "$repo/apps/cyfr/test/cyfr/old_test.exs"
stage deleted-test -l "$S/logs-deleted-test" handoff
grep -qx 'tests: skipped (no touched test) [0-9]*s' "$S/deleted-test.out" || fail "the deleted test was handed on: $(cat "$S/deleted-test.out")"
reset_tree
stage clean -l "$S/logs-clean" handoff
[ "$rc" = 0 ] || fail "exited $rc"
grep -qx 'format: ok [0-9]*s' "$S/clean.out" || fail 'format did not run'
grep -qx 'tests: skipped (no touched test) [0-9]*s' "$S/clean.out" || fail 'the tests row ran with no touched test'
grep -qx 'notes: skipped (no changed path matches notes/\*\*) [0-9]*s' "$S/clean.out" || fail "a skipped row carries no seconds: $(cat "$S/clean.out")"
for check in compile dialyzer arca notes; do grep -q "^$check: skipped (no changed path matches" "$S/clean.out" || fail "$check ran"; done

begin 'explicit paths replace the touched tests; a touched path with whitespace is refused with 65'
reset_tree
stage explicit -l "$S/logs-explicit" handoff -- apps/cyfr/test/cyfr/old_test.exs
[ "$(cat "$S/logs-explicit/tests.txt")" = apps/cyfr/test/cyfr/old_test.exs ] || fail 'the explicit paths were not handed on'
stage spaced -l "$S/logs-spaced" handoff -- 'apps/cyfr/test/a b_test.exs'
[ "$rc" = 65 ] && grep -qF "a touched test path holds whitespace: 'apps/cyfr/test/a b_test.exs'" "$S/spaced.err" || fail "explicit: $rc $(cat "$S/spaced.err")"
put "$repo/apps/cyfr/test/cyfr/sp ace_test.exs" x
stage spaced2 -l "$S/logs-spaced2" handoff
[ "$rc" = 65 ] || fail "a changed test with a space gave $rc"
[ ! -s "$STUB_CALLS" ] || fail 'a row ran before the refusal'
reset_tree

begin 'a row whose queue deadline passes or whose prerequisite is missing is not run, another that fails is failed, each fails the stage, and the rows after them still run'
table "${toy_rows[@]}" 'release|queue|1|60|-|always|echo #queue-deadline' 'release|missing|1|60|-|always|exit 69' \
  'release|broken|1|60|-|always|exit 3' 'release|after|1|60|-|always|echo after'
stage deadline -l "$S/logs-deadline" release
[ "$rc" = 1 ] || fail "exited $rc, not 1"
framed deadline 1
grep -qx 'queue: not run 75 [0-9]*s' "$S/deadline.out" || fail "the deadline row said: $(cat "$S/deadline.out")"
grep -qx 'missing: not run 69 [0-9]*s' "$S/deadline.out" || fail "the row missing a prerequisite said: $(cat "$S/deadline.out")"
grep -qx 'broken: failed 3 [0-9]*s' "$S/deadline.out" || fail "the failing row said: $(cat "$S/deadline.out")"
grep -qx 'after: ok [0-9]*s' "$S/deadline.out" || fail 'the row after them did not run'
table "${toy_rows[@]}" 'release|missing|1|60|-|always|exit 69' 'release|after|1|60|-|always|echo after'
stage missing-only -l "$S/logs-missing-only" release
[ "$rc" = 1 ] || fail "a stage whose one red row was not run exited $rc, not 1"
framed missing-only 1
table "${toy_rows[@]}"

begin 'a dry run names each row and runs nothing'
reset_tree
printf '# edit\n' >>"$repo/notes/today.md"
stage dry -n handoff
[ "$rc" = 0 ] || fail "exited $rc"
framed dry 0
grep -qxF 'would run notes (4 quarters): echo notes' "$S/dry.out" || fail "$(cat "$S/dry.out")"
grep -qxF 'would skip compile: no changed path matches apps/**,config/**' "$S/dry.out" || fail "$(cat "$S/dry.out")"
[ ! -s "$STUB_CALLS" ] || fail 'a dry run queued a row'
reset_tree

begin 'the table is read whole and refused at its first bad line with 65, before any row runs'
refused() { # LINE WHY ROW: the toy table with ROW appended at line LINE
  table "${toy_rows[@]}" "$3"
  stage refused -l "$S/logs-refused" handoff
  [ "$rc" = 65 ] || fail "\`$3\` gave $rc, not 65"
  grep -qF "stage: scripts/stages.tsv:$1: $2" "$S/refused.err" || fail "\`$3\` was refused as: $(cat "$S/refused.err")"
  [ ! -s "$STUB_CALLS" ] || fail "\`$3\`: a row ran before the refusal"
  framed refused 65
}
refused 9 "no stage is called 'deploy'" 'deploy|x|1|60|-|always|echo x'
refused 9 "no stage is called 'save handoff'" 'save handoff|x|1|60|-|always|echo x'
refused 9 "a row takes 1 or 4 quarters, not '2'" 'nightly|x|2|60|-|always|echo x'
refused 9 "a row takes 1 or 4 quarters, not 'scoped'" 'nightly|x|scoped|60|-|always|echo x'
refused 9 "a row takes 1 or 4 quarters, not 'exclusive'" 'nightly|x|exclusive|60|-|always|echo x'
refused 9 "'apps/**,,config/**' is not always, tests or comma-separated globs" 'handoff|x|1|60|-|apps/**,,config/**|echo x'
refused 9 "'apps/** config/**' is not always, tests or comma-separated globs" 'handoff|x|1|60|-|apps/** config/**|echo x'
refused 9 'handoff has a second check called compile' 'handoff|compile|1|60|-|always|echo x'
refused 9 'only save and handoff rows take tests' 'release|x|1|60|-|tests|echo x'
refused 9 'only save and handoff rows take globs' 'nightly|x|1|60|-|apps/**|echo x'
refused 9 "a row takes 1 or 4 quarters, not 'none'" 'handoff|x|none|-|-|always|git grep x'
refused 9 "the hold '-' is not seconds" 'handoff|x|1|-|-|always|echo x'
refused 9 "the check 'Compile' is not [a-z0-9-]+" 'handoff|Compile|1|60|-|always|echo x'
refused 9 'a row has seven fields separated by single tabs' 'handoff|x|1|60|-|echo x'
refused 9 'a field is empty' 'handoff||1|60|-|always|echo x'
refused 9 "the folder 'prod' is not dev, dev_pg, test, test_pg or -" 'handoff|x|1|60|prod|always|echo x'
refused 9 "the folder '_build/test' is not dev, dev_pg, test, test_pg or -" 'handoff|x|1|60|_build/test|always|echo x'
refused 9 'no check is called deps' 'handoff|deps|1|60|-|always|echo x'
table "${toy_rows[@]}"

begin 'a table that is missing or unreadable is refused with 65 naming it, and a stage is named whole'
mv "$repo/scripts/stages.tsv" "$S/stages.tsv.away"
stage missing -l "$S/logs-missing" release
[ "$rc" = 65 ] && grep -qF 'stage: scripts/stages.tsv: there is no stage table to read' "$S/missing.err" ||
  fail "a missing table gave $rc: $(cat "$S/missing.err")"
framed missing 65
[ ! -s "$STUB_CALLS" ] || fail 'a row ran without a table'
mv "$S/stages.tsv.away" "$repo/scripts/stages.tsv"
mkdir "$S/a-directory"
mv "$repo/scripts/stages.tsv" "$S/stages.tsv.away"
ln -s "$S/a-directory" "$repo/scripts/stages.tsv"
stage unreadable -l "$S/logs-unreadable" release
[ "$rc" = 65 ] || fail "a table that is a directory gave $rc"
rm "$repo/scripts/stages.tsv"
mv "$S/stages.tsv.away" "$repo/scripts/stages.tsv"
status=0; (cd "$repo" && scripts/stage.sh -n 'save handoff') >"$S/two.out" 2>&1 || status=$?
[ "$status" = 64 ] || fail "the stage 'save handoff' gave $status"

begin 'every exit is framed: 64 inside a heavy-check and on usage, and 69 outside a checkout'
for held in 1 4; do
  rc=0; (cd "$repo" && HEAVY_CHECK_HELD=$held scripts/stage.sh -n handoff) >"$S/held.out" 2>"$S/held.err" || rc=$?
  [ "$rc" = 64 ] && grep -qF 'run this outside scripts/heavy-check.sh' "$S/held.err" || fail "inside a heavy-check on $held: $rc"
  framed held 64
done
rc=0; (cd "$repo" && scripts/stage.sh -x handoff) >"$S/usage.out" 2>/dev/null || rc=$?
[ "$rc" = 64 ] || fail "an unknown option gave $rc"
framed usage 64
mkdir -p "$S/loose/scripts"
cp "$ROOT/scripts/stage.sh" "$S/loose/scripts/"
status=0; "$S/loose/scripts/stage.sh" -n handoff >"$S/loose.out" 2>"$S/loose.err" || status=$?
[ "$status" = 69 ] && grep -qF 'is not inside a git checkout' "$S/loose.err" || fail "outside a checkout: $status $(cat "$S/loose.err")"
rc=$status; framed loose 69
status=0; (cd "$repo" && scripts/stage.sh -n deploy) >/dev/null 2>&1 || status=$?
[ "$status" = 64 ] || fail "an unknown stage gave $status"

begin 'INT and TERM stop the running row and end with a frame'
table "${toy_rows[@]}" 'release|slow|1|60|-|always|exec sleep 6107'
for sig in INT:130 TERM:143; do
  name=${sig%%:*} want=${sig##*:}
  : >"$STUB_CALLS"
  (cd "$repo" && exec "${defaulted[@]}" INT scripts/stage.sh -l "$S/logs-$name" release) >"$S/$name.out" 2>"$S/$name.err" &
  runner=$!
  until_true 10 grep -q 'sleep 6107' "$STUB_CALLS" || fail "$name: the slow row never started"
  until_true 10 pgrep -f '^sleep 6107$' >/dev/null || fail "$name: no sleep found"
  sleeper=$(pgrep -f '^sleep 6107$' | head -1)
  [ -n "$sleeper" ] || fail "$name: no sleep found"
  kill -"$name" "$runner"
  until_true 10 eval '! kill -0 "$runner"' || {
    kill -KILL "$runner" "$sleeper" 2>/dev/null
    fail "$name: the stage was still running 10s after the signal"
  }
  status=0; wait "$runner" || status=$?
  [ "$status" = "$want" ] || fail "$name: exited $status, not $want"
  grep -qx "_EXIT=$runner $want" "$S/$name.out" || fail "$name: the last line is $(tail -n 1 "$S/$name.out")"
  [ "$(tail -n 2 "$S/$name.out" | head -n 1 | sed -E 's/ [0-9]+s$//')" = "slow: failed $want" ] ||
    fail "$name: the stopped row did not read failed $want: $(cat "$S/$name.out")"
  until_true 10 eval '! kill -0 "$sleeper"' || fail "$name: the row's command outlived the stage"
done
table "${toy_rows[@]}"

# Rows side by side, against a stand-in mix that records the dependency
# compiles; a row's wait on another row's file is bounded at 5 s.
mkdir -p "$S/fake-mix"
cat >"$S/fake-mix/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "${MIX_BUILD_PATH-default}" "${CYFR_DATABASE-}" "${MIX_ENV-}" "$*" >>"$FAKE_MIX_CALLS"
printf '%s %s\n' "${MIX_BUILD_PATH:-_build/${MIX_ENV:-dev}}" "$*" >>"$FAKE_MIX_USES"
echo "deps ${MIX_BUILD_PATH-default}" >>"$EVENTS"
exit "${FAKE_MIX_EXIT:-0}"
EOF
chmod +x "$S/fake-mix/mix"
cat >"$repo/scripts/wait-for" <<'EOF'
#!/usr/bin/env bash
for _ in $(seq 100); do [ -e "$1" ] && exit 0; sleep 0.05; done
exit 1
EOF
chmod +x "$repo/scripts/wait-for"
export FAKE_MIX_CALLS="$S/mix-calls" FAKE_MIX_USES="$S/mix-uses" EVENTS="$S/events"
lanes() { # NAME ARGS...: the toy stage with the stand-in mix; stdout to $S/NAME.out, rows' lines to $S/NAME.rows
  local name=$1
  shift
  : >"$FAKE_MIX_CALLS"
  : >"$FAKE_MIX_USES"
  : >"$EVENTS"
  : >"$STUB_CALLS"
  rc=0
  (cd "$repo" && PATH="$S/fake-mix:$PATH" scripts/stage.sh "$@") >"$S/$name.out" 2>"$S/$name.err" || rc=$?
  sed -n '2,$p' "$S/$name.out" | sed '$d' | sed -E 's/ [0-9]+s$//' >"$S/$name.rows"
}
# The toy table's fields are split at |, so no command here holds one.
lane_rows=(
  'handoff|first|1|60|dev|always|echo first >>"$EVENTS"; touch "$STAGE_LOGDIR/first.on"; scripts/wait-for "$STAGE_LOGDIR/beside.on" && sleep 0.2 && touch "$STAGE_LOGDIR/first.off"'
  'handoff|second|1|60|dev|always|[ -e "$STAGE_LOGDIR/first.off" ] && exit 3; exit 9'
  'handoff|third|1|60|dev|always|touch "$STAGE_LOGDIR/third.ran"'
  'handoff|beside|1|60|test|always|echo beside >>"$EVENTS"; touch "$STAGE_LOGDIR/beside.on"; scripts/wait-for "$STAGE_LOGDIR/first.on"'
  'handoff|loose|1|60|-|always|scripts/wait-for "$STAGE_LOGDIR/beside.on"'
  'handoff|quick|1|60|-|always|true'
)

begin "a folder's rows run one after another on one ticket whatever each ended with, other folders' rows and rows of none run beside them, after the dependencies are compiled into each folder in turn, and the summary keeps the table's order"
reset_tree
table "${lane_rows[@]}"
lanes lanes -l "$S/logs-lanes" handoff
[ "$rc" = 1 ] || fail "exited $rc, not 1: $(cat "$S/lanes.err")"
framed lanes 1
printf '%s\n' 'deps: ok' 'first: ok' 'second: failed 3' 'third: ok' 'beside: ok' 'loose: ok' 'quick: ok' >"$S/want"
diff "$S/want" "$S/lanes.rows" >/dev/null || fail "the rows said: $(tr '\n' ';' <"$S/lanes.rows")"
printf '%s\n' 'default|sqlite|dev|deps.loadpaths' '_build/test|sqlite|test|deps.loadpaths' >"$S/want"
diff "$S/want" "$FAKE_MIX_CALLS" >/dev/null || fail "the dependencies were compiled as: $(tr '\n' ';' <"$FAKE_MIX_CALLS")"
[ "$(head -n 2 "$EVENTS" | tr '\n' ';')" = 'deps default;deps _build/test;' ] || fail "a folder's row started before the dependencies were compiled: $(tr '\n' ';' <"$EVENTS")"
grep -qx '==> test' "$S/logs-lanes/deps.log" || fail "deps.log holds: $(cat "$S/logs-lanes/deps.log")"
grep -q -- '^-q 1 -t 1800 -- bash -c s=0' "$STUB_CALLS" || fail "the dependency compile was not queued on one quarter: $(cat "$STUB_CALLS")"
# One ticket per folder, holding each of its rows' holds and a minute
# for each stop; a row of no folder on a ticket of its own.
[ "$(grep -c -- '^-q 1 -t 60 -- bash -c ' "$STUB_CALLS")" = 2 ] || fail "the rows of no folder were not queued alone: $(cat "$STUB_CALLS")"
grep -q -- "^-q 1 -t 360 -- bash scripts/lib/stage-chain.sh [0-9]* $S/logs-lanes/dev.results 0 first 60  echo first" "$STUB_CALLS" &&
  grep -q -- "^-q 1 -t 120 -- bash scripts/lib/stage-chain.sh [0-9]* $S/logs-lanes/test.results 3 beside 60  echo beside" "$STUB_CALLS" ||
  fail "a folder's rows were not queued on one ticket each: $(cat "$STUB_CALLS")"
[ "$(wc -l <"$STUB_CALLS")" = 5 ] || fail "the stage queued other tickets: $(cat "$STUB_CALLS")"
[ -e "$S/logs-lanes/dev.queue.log" ] && [ -e "$S/logs-lanes/test.queue.log" ] || fail 'a ticket kept no log'
[ -e "$S/logs-lanes/third.ran" ] || fail 'the row after a failed one did not run'
lanes lanes-dry -n handoff
grep -qxF 'would compile deps (1 quarter): dev test' "$S/lanes-dry.out" || fail "the dry run said: $(cat "$S/lanes-dry.out")"
[ ! -s "$FAKE_MIX_CALLS" ] || fail 'a dry run compiled the dependencies'

begin "the caller's MIX_ENV and MIX_BUILD_PATH reach no row and no dependency compile: format stays in dev's folder and the tests in test's"
table 'handoff|format|1|60|dev|always|mix format' 'handoff|tests|1|60|test|always|env MIX_ENV=test mix test'
for caller in MIX_ENV=test "MIX_BUILD_PATH=$S/elsewhere"; do
  (export "$caller"; lanes inherited -l "$S/logs-inherited" handoff)
  rc=$(sed -n 's/^_EXIT=[0-9]* //p' "$S/inherited.out")
  [ "$rc" = 0 ] || fail "under $caller the stage exited $rc: $(cat "$S/inherited.err")"
  printf '%s\n' '_build/dev deps.loadpaths' '_build/test deps.loadpaths' '_build/dev format' '_build/test test' >"$S/want"
  diff "$S/want" <(LC_ALL=C sort "$FAKE_MIX_USES" | sed -n '/deps.loadpaths/p'; grep -v deps.loadpaths "$FAKE_MIX_USES" | LC_ALL=C sort) >/dev/null ||
    fail "under $caller the rows used: $(tr '\n' ';' <"$FAKE_MIX_USES")"
done

begin 'rows that name one folder compile no dependencies first, and a failed dependency compile fails the stage and starts no row that names a folder, each of which reads not run, while the rest still run'
table 'handoff|solo|1|60|dev|always|echo solo' 'handoff|free|1|60|-|always|echo free'
lanes one-folder -l "$S/logs-one-folder" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/one-folder.err")"
[ "$(tr '\n' ';' <"$S/one-folder.rows")" = 'solo: ok;free: ok;' ] || fail "the rows said: $(tr '\n' ';' <"$S/one-folder.rows")"
[ ! -s "$FAKE_MIX_CALLS" ] && [ ! -e "$S/logs-one-folder/deps.log" ] || fail 'one folder compiled the dependencies first'
table 'handoff|a|1|60|dev|always|echo a' 'handoff|b|1|60|test_pg|always|echo b' 'handoff|c|1|60|-|always|echo c'
FAKE_MIX_EXIT=1 lanes deps-failed -l "$S/logs-deps-failed" handoff
[ "$rc" = 1 ] || fail "exited $rc, not 1"
[ "$(tr '\n' ';' <"$S/deps-failed.rows")" = 'deps: failed 1;a: not run 69;b: not run 69;c: ok;' ] || fail "the rows said: $(tr '\n' ';' <"$S/deps-failed.rows")"
[ ! -e "$S/logs-deps-failed/a.log" ] && [ ! -e "$S/logs-deps-failed/b.log" ] && ! grep -q 'echo [ab]$' "$STUB_CALLS" ||
  fail "a row of a folder started after the failed compile: $(cat "$STUB_CALLS")"
[ "$(cut -d'|' -f1-3 "$FAKE_MIX_CALLS" | tr '\n' ';')" = 'default|sqlite|dev;_build/test_pg|postgres|test;' ] ||
  fail "a failed compile stopped the next folder's: $(tr '\n' ';' <"$FAKE_MIX_CALLS")"

begin 'a touched test that two test rows of one folder name runs once, in the row that names it, which the other says; another folder, other options and a row of no test keep it'
tests_rows=(
  'handoff|tests|1|60|test|tests|scripts/test-partitioned.sh -n 1 -a sqlite -- --warnings-as-errors $STAGE_TESTS'
  'handoff|rosters|1|60|test|always|scripts/test-partitioned.sh -n 1 -a sqlite -- --warnings-as-errors apps/cyfr/test/cyfr/a_test.exs'
  'handoff|arca|1|60|test|apps/arca/**|scripts/test-partitioned.sh -n 1 -a sqlite -- --warnings-as-errors apps/arca/test/'
  'handoff|traced|1|60|test|always|scripts/test-partitioned.sh -n 1 -a sqlite -- --trace apps/cyfr/test/cyfr/gone_test.exs'
  'handoff|tests-pg|1|60|test_pg|tests|scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors $STAGE_TESTS'
  'handoff|arca-pg|1|60|test_pg|apps/arca/**|scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors apps/arca/test'
  'handoff|listed|1|60|-|tests|printf "%s\n" $STAGE_TESTS >"$STAGE_LOGDIR/listed.txt"'
)
reset_tree
table "${tests_rows[@]}"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
printf '# edit\n' >>"$repo/apps/arca/lib/arca/x.ex"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/gone.ex"
: >"$RUNNER_CALLS"
lanes once -l "$S/logs-once" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/once.err")"
printf '%s\n' 'deps: ok' 'tests: ok' 'rosters: ok' 'arca: ok' 'traced: ok' 'tests-pg: ok' 'arca-pg: ok' 'listed: ok' >"$S/want"
diff "$S/want" "$S/once.rows" >/dev/null || fail "the rows said: $(tr '\n' ';' <"$S/once.rows")"
printf '%s\n' '-n 1 -a sqlite -- --warnings-as-errors apps/cyfr/test/cyfr/gone_test.exs' \
  '-n 1 -a sqlite -- --warnings-as-errors apps/cyfr/test/cyfr/a_test.exs' \
  '-n 1 -a sqlite -- --warnings-as-errors apps/arca/test/' \
  '-n 1 -a sqlite -- --trace apps/cyfr/test/cyfr/gone_test.exs' \
  '-n 1 -a postgres -- --warnings-as-errors apps/cyfr/test/cyfr/a_test.exs apps/cyfr/test/cyfr/gone_test.exs' \
  '-n 1 -a postgres -- --warnings-as-errors apps/arca/test' | LC_ALL=C sort >"$S/want"
diff "$S/want" <(LC_ALL=C sort "$RUNNER_CALLS") >/dev/null || fail "the runner ran: $(tr '\n' ';' <"$RUNNER_CALLS")"
printf '%s\n' '==> stage: apps/arca/test/arca/x_test.exs runs in arca' '==> stage: apps/cyfr/test/cyfr/a_test.exs runs in rosters' >"$S/want"
diff "$S/want" "$S/logs-once/tests.log" >/dev/null || fail "the tests row's log says: $(cat "$S/logs-once/tests.log")"
printf '%s\n' '==> stage: apps/arca/test/arca/x_test.exs runs in arca-pg' >"$S/want"
diff "$S/want" "$S/logs-once/tests-pg.log" >/dev/null || fail "the postgres tests row's log says: $(cat "$S/logs-once/tests-pg.log")"
[ "$(tr '\n' ' ' <"$S/logs-once/listed.txt")" = 'apps/arca/test/arca/x_test.exs apps/cyfr/test/cyfr/a_test.exs apps/cyfr/test/cyfr/gone_test.exs ' ] ||
  fail "a row of no folder lost touched tests: $(cat "$S/logs-once/listed.txt")"
# With every touched test run elsewhere, the row is skipped and says where.
reset_tree
table "${tests_rows[@]}"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
: >"$RUNNER_CALLS"
lanes once-all -l "$S/logs-once-all" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/once-all.err")"
grep -qx 'tests: skipped (every touched test runs in rosters)' "$S/once-all.rows" || fail "the rows said: $(tr '\n' ';' <"$S/once-all.rows")"
[ "$(grep -c -- '-a sqlite -- --warnings-as-errors apps/cyfr/test/cyfr/a_test.exs$' "$RUNNER_CALLS")" = 1 ] &&
  grep -qx -- '-n 1 -a postgres -- --warnings-as-errors apps/cyfr/test/cyfr/a_test.exs' "$RUNNER_CALLS" ||
  fail "the runner ran: $(tr '\n' ';' <"$RUNNER_CALLS")"
lanes once-dry -n handoff
grep -qxF 'would skip tests: every touched test runs in rosters' "$S/once-dry.out" || fail "the dry run said: $(cat "$S/once-dry.out")"
reset_tree

begin "handoff selects the tests in any app's tree that name a changed module, nested or grouped, and those that hold a changed fixture's or configuration file's name; save keeps its own"
reset_tree
for f in \
  'apps/sanctum/lib/sanctum/provider.ex|defmodule Sanctum.Provider do\n  defmodule Tools do\n  end\nend' \
  'apps/cyfr/test/sanctum/provider_test.exs|  alias Sanctum.Provider' \
  'apps/cyfr/test/sanctum/grouped_test.exs|  alias Sanctum.{\n    Context,\n    Provider\n  }' \
  'apps/cyfr/test/sanctum/tools_test.exs|  Sanctum.Provider.Tools.list()' \
  'apps/cyfr/test/sanctum/longer_test.exs|  Sanctum.ProviderSet.new() and Sanctum.Provider.Other.list()' \
  'apps/prima/lib/prima/probe.ex|defprotocol Prima.Probe do\n  def probe(term)\nend' \
  'apps/arca/lib/arca/probe_impl.ex|defimpl Prima.Probe, for: Arca.Thing do\n  def probe(_), do: :ok\nend' \
  'apps/cyfr/test/prima/probe_test.exs|  Prima.Probe.probe(1)' \
  'apps/cyfr/test/arca/thing_test.exs|  %Arca.Thing{}' \
  'apps/arca/lib/arca/probe_other.ex|defimpl Prima.Probe,\n  for: Arca.Other do\n  def probe(_), do: :ok\nend' \
  'apps/cyfr/test/arca/other_test.exs|  %Arca.Other{}' \
  'apps/cyfr/test/prima/fresh_test.exs|  Prima.Fresh.new()' \
  'config/runtime.exs|import Config' \
  'apps/cyfr/test/cyfr/runtime_config_test.exs|  File.read!("config/runtime.exs")' \
  'tests/fixtures/toy_wire.json|{}' \
  'apps/cyfr/test/opus/keeper_vectors_test.exs|  Path.expand("../../../../tests/fixtures/toy_wire.json", __DIR__)' \
  'apps/locus/test/locus/keeper_wire_test.exs|  vectors.("toy_wire.json")' \
  'apps/cyfr/test/test_helper.exs|ExUnit.start()' \
  'apps/cyfr/lib/cyfr/narrow.ex|defmodule Cyfr.Narrow do\nend' \
  'apps/cyfr/lib/cyfr/wide.ex|defmodule Cyfr.Wide do\nend' \
  'apps/cyfr/test/narrow/n_test.exs|  Cyfr.Narrow.go()' \
  'apps/cyfr/test/wide/w1_test.exs|  Cyfr.Wide.go()' \
  'apps/cyfr/test/wide/w2_test.exs|  Cyfr.Wide.go()' \
  'apps/cyfr/test/wide/w3_test.exs|  Cyfr.Wide.go()'; do
  mkdir -p "$(dirname "$repo/${f%%|*}")"
  printf '%b\n' "${f#*|}" >"$repo/${f%%|*}"
done
# The narrow name's one test weighs 200 s and the wide name's three 50 s
# each: either fits the 300 s budget alone, both do not, so which is taken
# shows the order. The rest weigh 1 s, the table's median.
{
  printf '1.0\t%s\n' apps/cyfr/test/arca/other_test.exs apps/cyfr/test/arca/thing_test.exs apps/cyfr/test/cyfr/runtime_config_test.exs \
    apps/cyfr/test/opus/keeper_vectors_test.exs apps/cyfr/test/prima/fresh_test.exs apps/cyfr/test/prima/probe_test.exs apps/cyfr/test/sanctum/grouped_test.exs apps/cyfr/test/sanctum/longer_test.exs apps/cyfr/test/sanctum/provider_test.exs \
    apps/cyfr/test/sanctum/tools_test.exs apps/locus/test/locus/keeper_wire_test.exs
  printf '200.0\t%s\n' apps/cyfr/test/narrow/n_test.exs
  printf '50.0\t%s\n' apps/cyfr/test/wide/w1_test.exs apps/cyfr/test/wide/w2_test.exs apps/cyfr/test/wide/w3_test.exs
} | LC_ALL=C sort -t "$(printf '\t')" -k2 >"$repo/scripts/test-partition-weights.tsv"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m consumers
select_rows=(
  'handoff|unit|1|60|-|tests|scripts/test-partitioned.sh -n 1 -a sqlite -- $STAGE_TESTS'
  'handoff|listed|1|60|-|tests|printf "%s\n" $STAGE_TESTS >"$STAGE_LOGDIR/listed.txt"'
  'save|listed|1|60|-|tests|printf "%s\n" $STAGE_TESTS >"$STAGE_LOGDIR/listed.txt"'
)
table "${select_rows[@]}"
printf '# edit\n' >>"$repo/apps/sanctum/lib/sanctum/provider.ex"
printf '# edit\n' >>"$repo/config/runtime.exs"
printf '{"edit": 1}\n' >"$repo/tests/fixtures/toy_wire.json"
printf '# edit\n' >>"$repo/apps/prima/lib/prima/probe.ex"
printf '# edit\n' >>"$repo/apps/arca/lib/arca/probe_impl.ex"
printf '# edit\n' >>"$repo/apps/arca/lib/arca/probe_other.ex"
# A file named -- is a changed path like any other, never an option: the
# new module after it in Git's listing still selects its reader.
: >"$repo/--"
printf 'defmodule Prima.Fresh do\nend\n' >"$repo/apps/prima/lib/prima/fresh.ex"
stage selected -l "$S/logs-selected" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/selected.err")"
printf '%s\n' apps/cyfr/test/arca/other_test.exs apps/cyfr/test/arca/thing_test.exs apps/cyfr/test/cyfr/runtime_config_test.exs \
  apps/cyfr/test/opus/keeper_vectors_test.exs apps/cyfr/test/prima/fresh_test.exs apps/cyfr/test/prima/probe_test.exs apps/cyfr/test/sanctum/grouped_test.exs apps/cyfr/test/sanctum/provider_test.exs apps/cyfr/test/sanctum/tools_test.exs \
  apps/locus/test/locus/keeper_wire_test.exs >"$S/want"
diff "$S/want" "$S/logs-selected/listed.txt" >/dev/null || fail "handoff selected: $(tr '\n' ' ' <"$S/logs-selected/listed.txt")"
[ ! -s "$S/logs-selected/unit.log" ] || fail "a selection within the budget left a name out: $(cat "$S/logs-selected/unit.log")"
rm -f "$repo/--" "$repo/apps/prima/lib/prima/fresh.ex"
stage selected-save -l "$S/logs-selected-save" save
[ "$rc" = 0 ] || fail "save exited $rc: $(cat "$S/selected-save.err")"
grep -qx 'listed: skipped (no touched test) [0-9]*s' "$S/selected-save.out" || fail "save selected tests: $(cat "$S/selected-save.out")"
# A selected test whose path holds a tab comes back whole and is refused.
reset_tree
tabbed="apps/cyfr/test/sanctum/tab$(printf '\t')name_test.exs"
printf '  alias Sanctum.Provider\n' >"$repo/$tabbed"
git -C "$repo" add -A && git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m tabbed
table "${select_rows[@]}"
printf '# edit\n' >>"$repo/apps/sanctum/lib/sanctum/provider.ex"
stage tabbed -l "$S/logs-tabbed" handoff
[ "$rc" = 65 ] && grep -qF "a touched test path holds whitespace: '$tabbed'" "$S/tabbed.err" ||
  fail "a selected path with a tab gave $rc: $(cat "$S/tabbed.err")"
reset_tree
git -C "$repo" rm -q -- "$tabbed" && git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m untabbed

begin "handoff's budget takes the names with the fewest test files first and names each it leaves out, with its count, on stderr and in the test rows' logs; a test_helper.exs stands for its app's suite"
reset_tree
table "${select_rows[@]}"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/wide.ex"
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/narrow.ex"
stage budget -l "$S/logs-budget" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/budget.err")"
[ "$(cat "$S/logs-budget/listed.txt")" = apps/cyfr/test/narrow/n_test.exs ] || fail "handoff selected: $(tr '\n' ' ' <"$S/logs-budget/listed.txt")"
grep -qF 'Cyfr.Wide (3 ' "$S/logs-budget/unit.log" && [ "$(grep -c . "$S/logs-budget/unit.log")" = 1 ] ||
  fail "the test row's log does not name the one name left out with its count: $(cat "$S/logs-budget/unit.log")"
grep -qF 'Cyfr.Wide (3 ' "$S/budget.err" || fail "the stage's stderr does not name the name left out: $(cat "$S/budget.err")"
reset_tree
table "${select_rows[@]}"
printf '# edit\n' >>"$repo/apps/cyfr/test/test_helper.exs"
stage helper -l "$S/logs-helper" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/helper.err")"
grep -qx 'unit: skipped (no touched test) [0-9]*s' "$S/helper.out" || fail "a changed test_helper.exs selected tests: $(cat "$S/helper.out")"
suite=$(git -C "$repo" ls-files 'apps/cyfr/test/*_test.exs' | grep -vc '^apps/cyfr/test/cluster/')
grep -qF "apps/cyfr/test/test_helper.exs ($suite " "$S/helper.err" ||
  fail "the stage did not name the suite it left out: $(cat "$S/helper.err")"
reset_tree
table "${toy_rows[@]}"

begin "a folder's rows report while its ticket runs, each row is stopped at its own hold and the next still runs, and a ticket that never starts leaves each of its rows not run"
table 'handoff|early|1|60|dev|always|true' \
  'handoff|late|1|60|dev|always|for _ in $(seq 300); do [ -e "$STAGE_LOGDIR/go" ] && exit 0; sleep 0.1; done; exit 1'
: >"$STUB_CALLS"
(cd "$repo" && scripts/stage.sh -l "$S/logs-early" handoff) >"$S/early.out" 2>"$S/early.err" &
runner=$!
until_true 10 grep -qx 'early: ok [0-9]*s' "$S/early.out" || { touch "$S/logs-early/go"; wait "$runner"; fail "the first row's line waited for the ticket: $(cat "$S/early.out")"; }
touch "$S/logs-early/go"
status=0; wait "$runner" || status=$?
[ "$status" = 0 ] && grep -qx 'late: ok [0-9]*s' "$S/early.out" || fail "exited $status: $(cat "$S/early.out")"
table 'handoff|held|1|1|dev|always|exec sleep 6121' 'handoff|next|1|60|dev|always|touch "$STAGE_LOGDIR/next.ran"'
stage held -l "$S/logs-held" handoff
[ "$rc" = 1 ] || fail "exited $rc, not 1"
grep -qx 'held: failed 124 [0-9]*s' "$S/held.out" && grep -qx 'next: ok [0-9]*s' "$S/held.out" || fail "the rows said: $(cat "$S/held.out")"
grep -qx '==> stage: hold deadline after 1s: the command was stopped' "$S/logs-held/held.log" || fail "the held row's log: $(cat "$S/logs-held/held.log")"
grep -q -- '^-q 1 -t 181 -- ' "$STUB_CALLS" || fail "the ticket's hold: $(cat "$STUB_CALLS")"
! pgrep -f '^sleep 6121$' >/dev/null || fail 'the held row outlived its hold'
table 'handoff|q1|1|60|dev|always|echo one #queue-deadline' 'handoff|q2|1|60|dev|always|echo two' 'handoff|free|1|60|-|always|true'
stage queued -l "$S/logs-queued" handoff
[ "$rc" = 1 ] || fail "exited $rc, not 1"
[ "$(sed -n '2,$p' "$S/queued.out" | sed '$d' | sed -E 's/ [0-9]+s$//' | tr '\n' ';')" = 'q1: not run 75;q2: not run 75;free: ok;dev ticket: not run 75;' ] ||
  fail "the rows said: $(cat "$S/queued.out")"

begin "a ticket killed outright fails the row it ran and every row after it, none of which starts, and its row's command is stopped"
table 'handoff|victim|1|60|dev|always|exec sleep 6122' 'handoff|orphan|1|60|dev|always|touch "$STAGE_LOGDIR/orphan.ran"' \
  'handoff|free|1|60|-|always|true'
(cd "$repo" && scripts/stage.sh -l "$S/logs-killed" handoff) >"$S/killed.out" 2>"$S/killed.err" &
runner=$!
until_true 10 pgrep -f '^sleep 6122$' >/dev/null || fail 'the row never started'
sleeper=$(pgrep -f '^sleep 6122$' | head -1)
chain=$(pgrep -f "stage-chain.sh .*$S/logs-killed/dev.results" | head -1)
[ -n "$chain" ] || fail 'no ticket found'
kill -KILL "$chain"
status=0; wait "$runner" || status=$?
[ "$status" = 1 ] || fail "exited $status, not 1: $(cat "$S/killed.out")"
[ "$(sed -n '2,$p' "$S/killed.out" | sed '$d' | sed -E 's/ [0-9]+s$//' | tr '\n' ';')" = 'victim: failed 137;orphan: failed 137;free: ok;dev ticket: failed 137;' ] ||
  fail "the rows said: $(cat "$S/killed.out")"
[ ! -e "$S/logs-killed/orphan.ran" ] || fail 'a row started after its ticket was killed'
until_true 20 eval '! kill -0 "$sleeper"' || { kill -KILL "$sleeper"; fail "the killed ticket's row outlived it"; }

begin "a ticket that ends red after every row of its folder passed fails the stage and says so after the rows"
table 'handoff|first|1|60|dev|always|true' 'handoff|after|1|60|dev|always|true' 'handoff|free|1|60|-|always|true'
STUB_TICKET_EXIT=42 stage red-ticket -l "$S/logs-red-ticket" handoff
[ "$rc" = 1 ] || fail "exited $rc, not 1: $(cat "$S/red-ticket.out")"
framed red-ticket 1
[ "$(sed -n '2,$p' "$S/red-ticket.out" | sed '$d' | sed -E 's/ [0-9]+s$//' | tr '\n' ';')" = 'first: ok;after: ok;free: ok;dev ticket: failed 42;' ] ||
  fail "the rows said: $(cat "$S/red-ticket.out")"

begin "a chain whose stage is gone starts no more rows; the row it was running ends as it would"
table 'handoff|first|1|60|dev|always|echo $$ >"$STAGE_LOGDIR/first.pid"; for _ in $(seq 300); do [ -e "$STAGE_LOGDIR/go" ] && exit 0; sleep 0.1; done; exit 1' \
  'handoff|second|1|60|dev|always|touch "$STAGE_LOGDIR/second.ran"'
(cd "$repo" && exec scripts/stage.sh -l "$S/logs-orphan" handoff) >"$S/orphan.out" 2>"$S/orphan.err" &
runner=$!
until_true 10 test -s "$S/logs-orphan/first.pid" || fail 'the first row never started'
chain=$(pgrep -f "stage-chain.sh .*$S/logs-orphan/dev.results" | head -1)
[ -n "$chain" ] || fail 'no ticket found'
kill -KILL "$runner"
wait "$runner" 2>/dev/null || :
touch "$S/logs-orphan/go"
until_true 20 eval '! kill -0 "$chain"' || { kill -KILL "$chain"; fail 'the ticket outlived its stage by more than its row'; }
[ ! -e "$S/logs-orphan/second.ran" ] || fail 'a row started after its stage was gone'
grep -qF "the stage $runner that queued this ticket is gone: second and the rows after it do not start" "$S/logs-orphan/dev.queue.log" ||
  fail "the ticket's log: $(cat "$S/logs-orphan/dev.queue.log")"
grep -qx '0 0 [0-9]*' "$S/logs-orphan/dev.results" || fail "the running row did not end as it would: $(cat "$S/logs-orphan/dev.results")"
table "${toy_rows[@]}"
reset_tree

begin 'INT and TERM stop every row running side by side, and no row starts after them'
table 'handoff|slow-a|1|60|dev|always|exec sleep 6111' 'handoff|after|1|60|dev|always|touch "$STAGE_LOGDIR/after.ran"' \
  'handoff|slow-b|1|60|-|always|exec sleep 6112'
for sig in INT:130 TERM:143; do
  name=${sig%%:*} want=${sig##*:}
  : >"$STUB_CALLS"
  (cd "$repo" && exec "${defaulted[@]}" INT scripts/stage.sh -l "$S/logs-side-$name" handoff) >"$S/side-$name.out" 2>"$S/side-$name.err" &
  runner=$!
  until_true 10 pgrep -f '^sleep 6111$' >/dev/null && until_true 10 pgrep -f '^sleep 6112$' >/dev/null ||
    fail "$name: the two rows never ran side by side"
  sleepers=$(pgrep -f '^sleep 611[12]$' | tr '\n' ' ')
  kill -"$name" "$runner"
  until_true 10 eval '! kill -0 "$runner"' || {
    kill -KILL "$runner" $sleepers 2>/dev/null
    fail "$name: the stage was still running 10s after the signal"
  }
  status=0; wait "$runner" || status=$?
  [ "$status" = "$want" ] || fail "$name: exited $status, not $want"
  for sleeper in $sleepers; do until_true 10 eval '! kill -0 "$sleeper"' || fail "$name: a row's command outlived the stage"; done
  [ ! -e "$S/logs-side-$name/after.ran" ] || fail "$name: a row started after the signal"
  [ "$(sed -n '2,$p' "$S/side-$name.out" | grep -v '^stage: ' | sed '$d' | sed -E 's/ [0-9]+s$//' | tr '\n' ';')" = \
    "slow-a: failed $want;after: failed $want;slow-b: failed $want;" ] ||
    fail "$name: the rows the signal stopped or kept from starting did not each read failed: $(cat "$S/side-$name.out")"
done
table "${toy_rows[@]}"
reset_tree

begin 'the handle proof without CYFR_RUN_DIR exits 69 and says it did not run, which the stage reports as not run'
table "${toy_rows[@]}" "release|handle|1|60|-|always|env -u CYFR_RUN_DIR bash '$ROOT/tests/handle-proof/run.sh'"
stage handle -l "$S/logs-handle" release
[ "$rc" = 1 ] || fail "exited $rc, not 1"
grep -qx 'handle: not run 69 [0-9]*s' "$S/handle.out" || fail "the handle proof's row said: $(cat "$S/handle.out")"
grep -qxF 'handle proof: not run: CYFR_RUN_DIR names no cyfr.run checkout, and the registry is built from one' "$S/logs-handle/handle.log" ||
  fail "the handle proof said: $(cat "$S/logs-handle/handle.log")"
table "${toy_rows[@]}"

# scripts/nightly.sh in the toy repository, against a stand-in gh that
# records its arguments, NUL-separated, and exits GH_EXIT.
cp "$ROOT/scripts/nightly.sh" "$repo/scripts/"
mkdir -p "$S/bin"
cat >"$S/bin/gh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\0' "$a"; done >>"$GH_CALLS"
exit "${GH_EXIT:-0}"
EOF
chmod +x "$S/bin/gh"
export GH_CALLS="$S/gh-calls"
nightly() { # NAME ARGS...: runs it; stdout to $S/NAME.out, stderr to $S/NAME.err, status to $rc
  local name=$1
  shift
  : >"$STUB_CALLS"
  : >"$GH_CALLS"
  rc=0
  (cd "$repo" && PATH="$S/bin:$PATH" scripts/nightly.sh "$@") >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
# Every gh call's arguments, a line each, a newline inside one shown as \n
# and a row's seconds as Ns.
gh_call() {
  python3 -I -c '
import re, sys
args = open(sys.argv[1], "rb").read().decode().split("\0")[:-1]
print("\n".join(re.sub(r" [0-9]+s(?=\n|$)", " Ns", a).replace("\n", "\\n") for a in args))' "$GH_CALLS"
}
want_call() { # COMMIT STATUS SUMMARY LOGS: the one call scripts/nightly.sh makes
  printf '%s\n' workflow run host-nightly.yml -f "commit=$1" -f "status=$2" -f "summary=$3" -f "logs=$4"
}
call_is() { # NAME COMMIT STATUS SUMMARY LOGS
  local name=$1
  shift
  diff <(want_call "$@") <(gh_call) >/dev/null || fail "$name: gh was called as: $(gh_call | tr '\n' ' ')"
}
night_rows=('nightly|first|1|60|-|always|echo first' 'nightly|second|1|60|-|always|echo second')
table "${toy_rows[@]}" "${night_rows[@]}"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m 'the nightly rows and scripts/nightly.sh'
head=$(git -C "$repo" rev-parse HEAD)

begin 'a green night reports status 0, the commit, the row lines and the log directory, and exits 0 with the stage framed on stdout'
nightly green -l "$S/logs-green"
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/green.err")"
framed green 0
call_is green "$head" 0 'first: ok Ns\nsecond: ok Ns' "$S/logs-green"
grep -qx 'first' "$S/logs-green/first.log" || fail 'a row log does not hold its output'
cmp -s "$S/green.out" "$S/logs-green/stage.out" || fail 'stdout is not the stage output it keeps'
grep -qxF "nightly: reported status 0 for $head" "$S/green.err" || fail "it said: $(cat "$S/green.err")"

begin 'a red night reaches gh with its status, its failed and not-run rows and the tree it tested, and exits with the stage status'
table "${toy_rows[@]}" "${night_rows[@]}" 'nightly|bad|1|60|-|always|exit 3' 'nightly|absent|1|60|-|always|exit 69'
nightly red -l "$S/logs-red"
[ "$rc" = 1 ] || fail "exited $rc, not 1"
call_is red "$head with changes" 1 'first: ok Ns\nsecond: ok Ns\nbad: failed 3 Ns\nabsent: not run 69 Ns' "$S/logs-red"

begin 'a stage that dies before any row is reported with its status and no row'
table "${toy_rows[@]}" "${night_rows[@]}" 'nightly|x|2|60|-|always|echo x'
nightly early -l "$S/logs-early"
[ "$rc" = 65 ] || fail "exited $rc, not 65"
call_is early "$head with changes" 65 '' "$S/logs-early"
grep -qF "a row takes 1 or 4 quarters, not '2'" "$S/logs-early/stage.err" || fail "the stage's refusal is not kept: $(cat "$S/logs-early/stage.err")"
reset_tree

begin 'a green night whose report does not reach GitHub exits 1 and says so'
GH_EXIT=1 nightly unreached -l "$S/logs-unreached"
[ "$rc" = 1 ] || fail "exited $rc, not 1"
call_is unreached "$head" 0 'first: ok Ns\nsecond: ok Ns' "$S/logs-unreached"
grep -qF "nightly: the report of status 0 for $head did not reach GitHub (gh exited 1)" "$S/unreached.err" || fail "it said: $(cat "$S/unreached.err")"

begin 'INT and TERM stop the stage and its row, and the stopped night is reported with the row it stopped'
table "${toy_rows[@]}" 'nightly|slow|1|60|-|always|exec sleep 6108'
for sig in INT:130 TERM:143; do
  name=${sig%%:*} want=${sig##*:}
  : >"$STUB_CALLS"
  : >"$GH_CALLS"
  (cd "$repo" && PATH="$S/bin:$PATH" exec "${defaulted[@]}" INT scripts/nightly.sh -l "$S/logs-night-$name") >"$S/night-$name.out" 2>"$S/night-$name.err" &
  runner=$!
  until_true 10 grep -q 'sleep 6108' "$STUB_CALLS" || fail "$name: the slow row never started"
  until_true 10 pgrep -f '^sleep 6108$' >/dev/null || fail "$name: no sleep found"
  sleeper=$(pgrep -f '^sleep 6108$' | head -1)
  kill -"$name" "$runner"
  until_true 10 eval '! kill -0 "$runner"' || {
    kill -KILL "$runner" "$sleeper" 2>/dev/null
    fail "$name: the night was still running 10s after the signal"
  }
  status=0; wait "$runner" || status=$?
  [ "$status" = "$want" ] || fail "$name: exited $status, not $want"
  until_true 10 eval '! kill -0 "$sleeper"' || fail "$name: the row's command outlived the night"
  call_is "$name" "$head with changes" 143 'slow: failed 143 Ns' "$S/logs-night-$name"
done
reset_tree

begin "the host nightly workflow holds no expression inside a script, asks for no permission but the watchdog's read of the runs and the issues, and carries each check's outcome to its issue"
# Each job's check is written out to be run as the runner runs a step.
python3 -I - "$ROOT/.github/workflows/host-nightly.yml" "$S/wf" <<'WF' || fail "the host nightly workflow: $(cat "$S/wf.err" 2>/dev/null)"
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
on = spec.get(True, spec.get("on"))
errors = []
if sorted(on) != ["schedule", "workflow_dispatch"]:
    errors.append(f"it runs on {sorted(on)}")
if spec.get("permissions") != {}:
    errors.append(f"the workflow's permissions are {spec.get('permissions')}")
jobs = spec["jobs"]
issues = {"contents": "read", "issues": "write"}
for name, want in (("report", issues), ("watchdog", {"actions": "read", **issues})):
    if jobs[name].get("permissions") != want:
        errors.append(f"the {name} job's permissions are {jobs[name].get('permissions')}")
base = {"GH_TOKEN": "${{ github.token }}", "GH_REPO": "${{ github.repository }}", "OUTCOME": "${{ steps.check.outcome }}",
        "RUN_URL": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"}
facts = {"report": {**base, **{k.upper(): f"${{{{ inputs.{k} }}}}" for k in ("commit", "status", "summary", "logs")}},
         "watchdog": base}
for name, command in (("report", "nightly"), ("watchdog", "watchdog")):
    steps = jobs[name]["steps"]
    if len(steps) != 3:
        errors.append(f"{name} has {len(steps)} steps")
        continue
    check, checkout, issue = steps
    for step in steps:
        if "${{" in step.get("run", ""):
            errors.append(f"{name}'s script holds an expression")
    if check.get("id") != "check" or "if" in check:
        errors.append(f"{name}'s first step is not its check, always run")
    if not checkout.get("uses", "").startswith("actions/checkout@") or checkout.get("with", {}).get("sparse-checkout") != "scripts/ci/reds.py":
        errors.append(f"{name}'s second step does not check out scripts/ci/reds.py alone")
    for step in (checkout, issue):
        if step.get("if") != "${{ !cancelled() }}":
            errors.append(f"{name}'s step {step.get('name') or step.get('uses')} does not run after a failed check")
    # Every fact reds.py reads in that step, each bound to its source: one
    # left out reaches the script as empty.
    if issue.get("run") != f"python3 -I scripts/ci/reds.py {command}" or issue.get("env") != facts[name]:
        errors.append(f"{name}'s last step does not hand reds.py {command} the check's outcome and its facts: {issue.get('env')}")
    open(f"{sys.argv[2]}-{name}.sh", "w").write(check["run"])
if errors:
    open(sys.argv[2] + ".err", "w").write("; ".join(errors))
    sys.exit(1)
WF

begin "the workflow's report fails unless the stage exited exactly 0 and the report is what nightly.sh sends"
sha40=0123456789abcdef0123456789abcdef01234567
green_rows=$'janitor: ok 9s\ninstall-screen-proof: ok 1702s'
red_rows=$'janitor: ok 9s\nhandle-proof: not run 69 0s'
report() { # STATUS SUMMARY [COMMIT [LOGS]]: runs the report step; its exit in $rc
  : >"$S/step-summary"
  rc=0
  env -i PATH="$PATH" GITHUB_STEP_SUMMARY="$S/step-summary" STATUS="$1" SUMMARY="$2" COMMIT="${3-$sha40}" \
    LOGS="${4-/tmp/cyfr-stage.nightly.Ab1sCd}" bash --noprofile --norc -eo pipefail "$S/wf-report.sh" >"$S/report.out" 2>&1 || rc=$?
}
refused() { # WHAT: the report just run exited 1 and printed nothing it was sent
  [ "$rc" = 1 ] && [ ! -s "$S/step-summary" ] && ! grep -qi 'planted' "$S/report.out" ||
    fail "a report with $1 exited $rc, printed: $(cat "$S/report.out") $(cat "$S/step-summary")"
}
report 0 "$green_rows"
[ "$rc" = 0 ] || fail "a green report failed: $(cat "$S/report.out")"
grep -qxF 'install-screen-proof: ok 1702s' "$S/step-summary" || fail "the summary does not hold the rows: $(cat "$S/step-summary")"
report 0 "$green_rows" "$sha40 with changes"
[ "$rc" = 0 ] || fail "a green report of a changed tree failed: $(cat "$S/report.out")"
for status in 1 69 75 143 '' 00 ' 0' '0 ' x; do
  report "$status" "$red_rows"
  [ "$rc" = 1 ] || fail "a report of status '$status' exited $rc, not 1"
done
report 69 "$red_rows"
grep -qF 'exited 69: a check failed or did not run' "$S/report.out" || fail "a red report said: $(cat "$S/report.out")"
report 0 "$green_rows" abc
[ "$rc" = 1 ] || fail "a report of commit 'abc' exited $rc, not 1"
# A row is never skipped in the nightly, so no row holds free text: none
# carries a workflow command, the runner's older ##[ form, or a carriage
# return, at which the runner splits a line and the summary's fence could
# close; nor does any other input.
report 0 $'janitor: ok 9s\n::error::planted'
refused 'a workflow command line'
report 0 'handle-proof: skipped (##[error]planted) 0s'
refused 'a legacy workflow command in a skipped row'
report 0 $'handle-proof: skipped (\r::error::planted) 0s'
refused 'a carriage return before a workflow command'
report 0 $'handle-proof: skipped (\r```\r# PLANTED OUTSIDE FENCE\r```text\r) 0s'
refused 'carriage returns around a closed fence'
report 0 $'janitor: ok 9s\r'
refused 'a carriage return in a row'
report $'0\r' "$green_rows"
refused 'a carriage return in the status'
report 0 "$green_rows" "$sha40"$'\r'
refused 'a carriage return in the commit'
report 0 "$green_rows" "$sha40" $'/tmp/cyfr-stage.nightly.Ab1sCd\r'
refused 'a carriage return in the log path'

begin "the workflow's watchdog passes only on a report run that completed within 26 hours, never on its own"
mkdir -p "$S/watch-bin" "$S/runner"
cat >"$S/watch-bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$WATCH_CALL"
cat "$WATCH_RUNS"
EOF
chmod +x "$S/watch-bin/gh"
ago() { date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ; }
run_json() { # EVENT STATUS CONCLUSION HOURS-AGO
  printf '{"event":"%s","status":"%s","conclusion":%s,"created_at":"%s"}' "$1" "$2" "$3" "$(ago "$4")"
}
watchdog() { # RUN...: the watchdog step against a gh that lists RUNs; its exit in $rc
  local IFS=,
  printf '{"total_count":%s,"workflow_runs":[%s]}' "$#" "$*" >"$S/runs.json"
  rc=0
  env -i PATH="$S/watch-bin:$PATH" RUNNER_TEMP="$S/runner" GH_TOKEN=x REPOSITORY=cyfrworks/cyfr WATCH_RUNS="$S/runs.json" \
    WATCH_CALL="$S/watch-call" bash --noprofile --norc -eo pipefail "$S/wf-watchdog.sh" >"$S/watch.out" 2>&1 || rc=$?
}
watchdog "$(run_json workflow_dispatch completed '"failure"' 2)"
[ "$rc" = 0 ] || fail "a red report two hours old did not satisfy it: $(cat "$S/watch.out")"
grep -qx 'event=workflow_dispatch' "$S/watch-call" && grep -qx 'status=completed' "$S/watch-call" && grep -q '^created=>=' "$S/watch-call" ||
  fail "it asked for: $(tr '\n' ' ' <"$S/watch-call")"
watchdog "$(run_json workflow_dispatch completed '"success"' 25)"
[ "$rc" = 0 ] || fail "a green report 25 hours old did not satisfy it: $(cat "$S/watch.out")"
watchdog "$(run_json schedule completed '"success"' 1)" "$(run_json workflow_dispatch in_progress null 1)" \
  "$(run_json workflow_dispatch completed '"cancelled"' 1)" "$(run_json workflow_dispatch completed '"success"' 27)"
[ "$rc" = 1 ] || fail "its own run, a running report, a cancelled one and one 27 hours old satisfied it: $(cat "$S/watch.out")"
grep -qF 'no report from the host' "$S/watch.out" || fail "it said: $(cat "$S/watch.out")"
watchdog
[ "$rc" = 1 ] || fail 'no run at all satisfied it'

begin 'flakes: failing in both and flaky in one only where both runs completed alike, and unknown for an incomplete partition, an exit of 3 or exclusions in one run only, on either side'
night="$S/night"
mkdir -p "$night"
# plant LOG-NAME RUN-DIR EXIT...: a suite row's log over one partition per
# exit, the partitions holding Arca's a test, Cyfr's b and c tests,
# Sanctum's d test and Locus's e test, in that order.
planted_files=(apps/arca/test/a_test.exs apps/cyfr/test/b_test.exs apps/cyfr/test/c_test.exs
  apps/sanctum/test/d_test.exs apps/locus/test/e_test.exs)
plant() {
  local log=$1 dir=$2 i=0 status
  shift 2
  {
    echo '_START=1'
    for status in "$@"; do
      i=$((i + 1))
      echo "==> partition $i/$#"
      [ "$status" = 0 ] || printf '    partition exited %s; its account:\n' "$status"
    done
    echo "==> logs and disposable resources kept: $dir"
    echo '_EXIT=1 1'
  } >"$night/$log.log"
  mkdir -p "$dir/assign"
  for ((i = 1; i <= $#; i++)); do printf '%s\0' "${planted_files[$((i - 1))]}" >"$dir/assign/p$i"; done
}
# A failure as ExUnit prints it in an umbrella run: its file named from the
# umbrella's root (Mix's test_location_relative_path), as the real runner's
# partition logs show it.
failure() { printf '  %s) test %s (%s)\n     %s:7\n' "$1" "$2" "$3" "$4"; }
# sqlite-1's d test fails as sqlite-2's does, but sqlite-2's Sanctum part
# excluded a test where sqlite-1's excluded none; its e test fails in a
# partition that exited 3 (failures and warnings) and passes in sqlite-2's
# complete one. Neither run vouches for the other there.
plant sqlite-1 "$S/run-s1" 0 2 2 2 3
plant sqlite-2 "$S/run-s2" 0 2 0 2 0
{ echo '==> sanctum'; failure 1 'fails in both' Sanctum.DTest apps/sanctum/test/d_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-s1/p4.log"
{ echo '==> sanctum'; failure 1 'fails in both' Sanctum.DTest apps/sanctum/test/d_test.exs; echo 'Result: 1/3 passed, 1 excluded'; } >"$S/run-s2/p4.log"
{ echo '==> locus'; failure 1 'warned once' Locus.ETest apps/locus/test/e_test.exs; echo 'Result: 1/2 passed'; } >"$S/run-s1/p5.log"
printf '==> locus\nResult: 2 passed\n' >"$S/run-s2/p5.log"
printf '==> arca\nResult: 3 passed\n' >"$S/run-s1/p1.log"
{ echo '==> cyfr'; failure 1 'fails always' Cyfr.BTest apps/cyfr/test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-s1/p2.log"
{ echo '==> cyfr'; failure 1 'fails once' Cyfr.CTest apps/cyfr/test/c_test.exs; echo 'Result: 1/2 passed'; } >"$S/run-s1/p3.log"
printf '==> arca\nResult: 3 passed\n' >"$S/run-s2/p1.log"
{ echo '==> cyfr'; failure 1 'fails always' Cyfr.BTest apps/cyfr/test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-s2/p2.log"
printf '==> cyfr\nResult: 2 passed\n' >"$S/run-s2/p3.log"
# postgres-2 fails three tests; postgres-1 cannot vouch for any of them:
# its Arca partition never wrote Arca's Result line, its b partition
# exited 3 (failures and warnings), and its c partition excluded none where
# postgres-2's excluded one.
plant postgres-2 "$S/run-p2" 2 2 2 0 0
{ echo '==> arca'; failure 1 'cut short' Arca.ATest apps/arca/test/a_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-p2/p1.log"
{ echo '==> cyfr'; failure 1 'warned' Cyfr.BTest apps/cyfr/test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-p2/p2.log"
{ echo '==> cyfr'; failure 1 'excluded elsewhere' Cyfr.CTest apps/cyfr/test/c_test.exs; echo 'Result: 1/2 passed, 1 excluded'; } >"$S/run-p2/p3.log"
plant postgres-1 "$S/run-p1" 0 3 0 0 0
printf '==> arca\n' >"$S/run-p1/p1.log"
printf '==> cyfr\nResult: 3 passed\n' >"$S/run-p1/p2.log"
printf '==> cyfr\nResult: 2 passed\n' >"$S/run-p1/p3.log"
for run in p1 p2; do
  printf '==> sanctum\nResult: 3 passed\n' >"$S/run-$run/p4.log"
  printf '==> locus\nResult: 2 passed\n' >"$S/run-$run/p5.log"
done
python3 -I "$ROOT/scripts/lib/nightly.py" flakes "$night" >"$S/flakes.txt"
printf '%s\n' \
  $'failing\tsqlite\tcyfr\tfails always (Cyfr.BTest)\tfailed in sqlite-1 and sqlite-2' \
  $'flaky\tsqlite\tcyfr\tfails once (Cyfr.CTest)\tfailed in sqlite-1' \
  $'unknown\tsqlite\tsanctum\tfails in both (Sanctum.DTest)\tfailed in sqlite-1 and sqlite-2' \
  $'unknown\tsqlite\tlocus\twarned once (Locus.ETest)\tfailed in sqlite-1' \
  $'unknown\tpostgres\tarca\tcut short (Arca.ATest)\tfailed in postgres-2' \
  $'unknown\tpostgres\tcyfr\texcluded elsewhere (Cyfr.CTest)\tfailed in postgres-2' \
  $'unknown\tpostgres\tcyfr\twarned (Cyfr.BTest)\tfailed in postgres-2' | LC_ALL=C sort >"$S/want"
LC_ALL=C sort "$S/flakes.txt" | diff "$S/want" - >/dev/null || fail "the verdicts: $(cat "$S/flakes.txt")"
# The positive control: postgres-1 whole, exiting 0, with the same
# exclusions, makes all three flaky.
plant postgres-1 "$S/run-p1" 0 0 0 0 0
printf '==> arca\nResult: 3 passed\n' >"$S/run-p1/p1.log"
printf '==> cyfr\nResult: 2 passed, 1 excluded\n' >"$S/run-p1/p3.log"
python3 -I "$ROOT/scripts/lib/nightly.py" flakes "$night" >"$S/flakes2.txt"
[ "$(grep -c $'^flaky\tpostgres\t' "$S/flakes2.txt")" = 3 ] || fail "the control: $(cat "$S/flakes2.txt")"

begin 'weights: each file keeps its larger value, under the tracked header, and the differing rows are counted'
mkdir -p "$S/fake-elixir" "$S/wroot/scripts" "$night/timings-1" "$night/timings-2"
cat >"$S/fake-elixir/elixir" <<'EOF'
#!/usr/bin/env bash
cat "$3/weights.txt"
EOF
chmod +x "$S/fake-elixir/elixir"
printf '1.5\tapps/a_test.exs\n0.2\tapps/b_test.exs\n' >"$night/timings-1/weights.txt"
printf '0.9\tapps/a_test.exs\n0.4\tapps/b_test.exs\n3.0\tapps/c_test.exs\n' >"$night/timings-2/weights.txt"
printf '# header\n1.5\tapps/a_test.exs\n0.2\tapps/b_test.exs\n' >"$S/wroot/scripts/test-partition-weights.tsv"
out=$(cd "$S/wroot" && PATH="$S/fake-elixir:$PATH" python3 -I "$ROOT/scripts/lib/nightly.py" weights "$night")
[ "$out" = '2 rows differ from scripts/test-partition-weights.tsv' ] || fail "it said: $out"
printf '# header\n1.5\tapps/a_test.exs\n0.4\tapps/b_test.exs\n3.0\tapps/c_test.exs\n' | diff - "$night/test-partition-weights.tsv" >/dev/null ||
  fail "the table: $(cat "$night/test-partition-weights.tsv")"
[ "$(cat "$S/wroot/scripts/test-partition-weights.tsv")" = "$(printf '# header\n1.5\tapps/a_test.exs\n0.2\tapps/b_test.exs')" ] ||
  fail 'the tracked table changed'

begin "a handoff's receipt names HEAD's commit and tree and reads committed on a clean tree, and computing it leaves the index, the working files and the refs as they were; save writes none"
# A repository of its own, with the toy's stand-ins, so what these cases
# commit changes no other case's tree.
rrepo="$S/receipt-repo"
git init -q -b main "$rrepo"
cp -R "$repo/scripts" "$rrepo/"
cat >"$rrepo/scripts/heavy-check.sh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
case "$*" in *test-partitioned*) [ -z "${RECEIPT_QUEUE_DEADLINE:-}" ] || exit 75 ;; esac
exec "$@"
EOF
printf '%s\n' \
  'handoff|unit|1|60|-|tests|scripts/test-partitioned.sh -n 1 -a sqlite -- $STAGE_TESTS' \
  'handoff|unit-pg|1|60|-|tests|scripts/test-partitioned.sh -n 1 -a postgres -- $STAGE_TESTS' \
  'handoff|edit|1|60|-|always|if [ -n "${RECEIPT_EDIT:-}" ]; then echo edited >>"$RECEIPT_EDIT"; fi' \
  'handoff|fail|1|60|-|always|exit "${RECEIPT_FAIL:-0}"' \
  'save|unit|1|60|-|tests|scripts/test-partitioned.sh -n 1 -a sqlite -- $STAGE_TESTS' | tr '|' '\t' >"$rrepo/scripts/stages.tsv"
printf '200.0\t%s\n' apps/cyfr/test/wide/w1_test.exs apps/cyfr/test/wide/w2_test.exs apps/cyfr/test/wide/w3_test.exs \
  >"$rrepo/scripts/test-partition-weights.tsv"
put "$rrepo/apps/cyfr/lib/cyfr/a.ex" 'defmodule Cyfr.A do end'
put "$rrepo/apps/cyfr/test/cyfr/a_test.exs" '  Cyfr.A'
put "$rrepo/apps/cyfr/lib/cyfr/wide.ex" 'defmodule Cyfr.Wide do end'
for w in w1 w2 w3; do put "$rrepo/apps/cyfr/test/wide/${w}_test.exs" '  Cyfr.Wide.go()'; done
put "$rrepo/notes.txt" 'notes'
git -C "$rrepo" add -A
git -C "$rrepo" -c user.name=test -c user.email=test@invalid commit -q -m receipt
rstage() { # NAME ARGS...: the receipt repository's stage, logs in $S/logs-NAME; status to $rc
  local name=$1
  shift
  rc=0
  (cd "$rrepo" && scripts/stage.sh -l "$S/logs-$name" "$@") >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
# What a run could have touched: the index's bytes, the status of every
# file, ignored ones too, and every ref, the stash's included.
untouched() {
  sha256sum "$(git -C "$rrepo" rev-parse --path-format=absolute --git-path index)" | cut -d' ' -f1
  git -C "$rrepo" status --porcelain=v2 --branch --ignored --untracked-files=all
  git -C "$rrepo" for-each-ref
  git -C "$rrepo" stash list
}
untouched >"$S/before"
rstage committed handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/committed.err")"
untouched >"$S/after"
diff "$S/before" "$S/after" >/dev/null || fail "the receipt touched the checkout: $(diff "$S/before" "$S/after")"
head=$(git -C "$rrepo" rev-parse HEAD) tree=$(git -C "$rrepo" rev-parse 'HEAD^{tree}')
printf '%s\n' 'stage handoff' 'result passed' "end-commit $head" "end-commit-tree $tree" "start-tree $tree" "end-tree $tree" \
  'state committed' >"$S/want"
head -n 7 "$S/logs-committed/receipt" | diff "$S/want" - >/dev/null || fail "the receipt opens: $(head -n 7 "$S/logs-committed/receipt")"
grep -qx "stage: receipt: handoff passed, commit $head, tree $tree, committed, logs $S/logs-committed" "$S/committed.err" ||
  fail "the receipt's line: $(grep receipt "$S/committed.err")"
grep -qx 'row unit: skipped (no touched test) [0-9]*s' "$S/logs-committed/receipt" &&
  grep -qx 'row fail: ok [0-9]*s' "$S/logs-committed/receipt" || fail "the receipt's rows: $(grep '^row' "$S/logs-committed/receipt")"
rstage committed-save save
[ "$rc" = 0 ] && [ ! -e "$S/logs-committed-save/receipt" ] && ! grep -q receipt "$S/committed-save.err" ||
  fail "save wrote a receipt or exited $rc"

begin "an uncommitted edit reads uncommitted with the tree it tested, and the receipt names each adapter's tests and each name left out with its count"
printf '# edit\n' >>"$rrepo/apps/cyfr/lib/cyfr/a.ex"
printf '# edit\n' >>"$rrepo/apps/cyfr/lib/cyfr/wide.ex"
untouched >"$S/before"
rstage uncommitted handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/uncommitted.err")"
untouched >"$S/after"
diff "$S/before" "$S/after" >/dev/null || fail "the receipt touched the checkout: $(diff "$S/before" "$S/after")"
start=$(sed -n 's/^start-tree //p' "$S/logs-uncommitted/receipt")
[ -n "$start" ] && [ "$start" != "$tree" ] && grep -qx "end-tree $start" "$S/logs-uncommitted/receipt" &&
  grep -qx 'state uncommitted' "$S/logs-uncommitted/receipt" || fail "the receipt reads: $(head -n 7 "$S/logs-uncommitted/receipt")"
# The tree it tested is the commit of the working files.
git -C "$rrepo" add -A
[ "$(git -C "$rrepo" write-tree)" = "$start" ] || fail "the start tree is not the working files' tree"
git -C "$rrepo" reset -q
grep -qx 'selected unit sqlite apps/cyfr/test/cyfr/a_test.exs' "$S/logs-uncommitted/receipt" &&
  grep -qx 'selected unit-pg postgres apps/cyfr/test/cyfr/a_test.exs' "$S/logs-uncommitted/receipt" &&
  grep -qx 'left Cyfr.Wide 3' "$S/logs-uncommitted/receipt" || fail "the receipt's selection: $(grep -E '^(selected|left)' "$S/logs-uncommitted/receipt")"
grep -qx "stage: receipt: handoff passed, commit $head, tree $tree, uncommitted, logs $S/logs-uncommitted" "$S/uncommitted.err" ||
  fail "the receipt's line: $(grep receipt "$S/uncommitted.err")"
git -C "$rrepo" checkout -q -- .

begin 'a file changed while a row runs reads moved, and a failing row still leaves a receipt with its result'
RECEIPT_EDIT="$rrepo/notes.txt" rstage moved handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/moved.err")"
grep -qx "start-tree $tree" "$S/logs-moved/receipt" && ! grep -qx "end-tree $tree" "$S/logs-moved/receipt" &&
  grep -qx 'state moved' "$S/logs-moved/receipt" || fail "the receipt reads: $(head -n 7 "$S/logs-moved/receipt")"
grep -q ', moved, logs ' "$S/moved.err" || fail "the receipt's line: $(grep receipt "$S/moved.err")"
git -C "$rrepo" checkout -q -- .
RECEIPT_FAIL=3 rstage failing handoff
[ "$rc" = 1 ] || fail "a failing row's stage exited $rc"
grep -qx 'result failed 1' "$S/logs-failing/receipt" && grep -qx 'row fail: failed 3 [0-9]*s' "$S/logs-failing/receipt" &&
  grep -qx 'state committed' "$S/logs-failing/receipt" || fail "the failing run's receipt: $(cat "$S/logs-failing/receipt")"
grep -qx "stage: receipt: handoff failed 1, commit $head, tree $tree, committed, logs $S/logs-failing" "$S/failing.err" ||
  fail "the receipt's line: $(grep receipt "$S/failing.err")"

begin "a commit made after the stage starts, before its first row, reads moved, never committed for the new commit; a receipt's commit and tree are one commit's"
# A stand-in git commits a new table the moment the stage asks for its
# base, after the table is read, as another writer could; and, asked for
# HEAD by the receipt, moves HEAD on before answering again.
mkdir -p "$S/race-bin"
real_git=$(command -v git)
cat >"$S/race-bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = merge-base ] && [ -n "\${RACE_TABLE:-}" ] && [ ! -e "\$RACE_TABLE.done" ]; then
  : >"\$RACE_TABLE.done"
  sed -i s/old-command/new-command/ scripts/stages.tsv
  "$real_git" add scripts/stages.tsv && "$real_git" -c user.name=test -c user.email=test@invalid commit -qm 'new table' >&2
fi
args="\$*"
if [ -n "\${RACE_HEAD:-}" ] && [ "\$args" != "\${args#rev-parse -q --verify HEAD^}" ] && [ ! -e "\$RACE_HEAD.done" ]; then
  : >"\$RACE_HEAD.done"
  "$real_git" "\$@"; s=\$?
  "$real_git" update-ref HEAD "\$RACE_NEXT"
  exit \$s
fi
exec "$real_git" "\$@"
EOF
chmod +x "$S/race-bin/git"
cp "$rrepo/scripts/stages.tsv" "$S/receipt-table"
printf 'handoff\tread\t1\t60\t-\talways\techo old-command\n' >"$rrepo/scripts/stages.tsv"
git -C "$rrepo" -c user.name=test -c user.email=test@invalid commit -qam 'old table'
rc=0; (cd "$rrepo" && PATH="$S/race-bin:$PATH" RACE_TABLE="$S/race-table" scripts/stage.sh -l "$S/logs-race" handoff) >"$S/race.out" 2>"$S/race.err" || rc=$?
[ "$rc" = 0 ] && grep -qx old-command "$S/logs-race/read.log" || fail "the raced stage exited $rc or ran: $(cat "$S/logs-race/read.log" 2>&1)"
grep -qx 'state moved' "$S/logs-race/receipt" && [ "$(sed -n 's/^start-tree //p' "$S/logs-race/receipt")" = "$(git -C "$rrepo" rev-parse 'HEAD~1^{tree}')" ] ||
  fail "a commit after the start reads: $(head -n 7 "$S/logs-race/receipt")"
# HEAD moved on between the receipt's reads: its commit and tree stay one commit's.
next=$(git -C "$rrepo" -c user.name=test -c user.email=test@invalid commit-tree "$(git -C "$rrepo" hash-object -t tree /dev/null)" -p HEAD -m next)
here=$(git -C "$rrepo" rev-parse HEAD)
rc=0; (cd "$rrepo" && PATH="$S/race-bin:$PATH" RACE_HEAD="$S/race-head" RACE_NEXT="$next" scripts/stage.sh -l "$S/logs-head" handoff) >"$S/head.out" 2>"$S/head.err" || rc=$?
[ -e "$S/race-head.done" ] || fail 'HEAD was not moved while the receipt read it'
commit=$(sed -n 's/^end-commit //p' "$S/logs-head/receipt")
[ "$commit" = "$here" ] && [ "$(sed -n 's/^end-commit-tree //p' "$S/logs-head/receipt")" = "$(git -C "$rrepo" rev-parse "$commit^{tree}")" ] ||
  fail "the receipt pairs $commit with another commit's tree: $(head -n 7 "$S/logs-head/receipt")"
git -C "$rrepo" update-ref HEAD "$here"
cp "$S/receipt-table" "$rrepo/scripts/stages.tsv"
git -C "$rrepo" -c user.name=test -c user.email=test@invalid commit -qam 'the receipt table'
head=$(git -C "$rrepo" rev-parse HEAD) tree=$(git -C "$rrepo" rev-parse 'HEAD^{tree}')

begin 'a receipt that cannot be written, or written whole, fails a stage that would pass and prints no receipt line; a row the queue never started has no line that says its tests ran'
mkdir -p "$S/logs-unwritable/receipt"
rstage unwritable handoff
[ "$rc" = 1 ] && grep -qF "stage: receipt: could not be written to $S/logs-unwritable/receipt" "$S/unwritable.err" &&
  ! grep -q '^stage: receipt: handoff' "$S/unwritable.err" || fail "an unwritable receipt gave $rc: $(cat "$S/unwritable.err")"
# A receipt.part that opens and refuses the write, as a full disk does.
mkdir -p "$S/logs-full"
ln -s /dev/full "$S/logs-full/receipt.part"
rstage full handoff
[ "$rc" = 1 ] && grep -qF "stage: receipt: could not be written to $S/logs-full/receipt" "$S/full.err" &&
  ! grep -q '^stage: receipt: handoff' "$S/full.err" && [ ! -e "$S/logs-full/receipt" ] && [ ! -L "$S/logs-full/receipt" ] ||
  fail "a receipt the disk refused gave $rc: $(cat "$S/full.err"; ls -l "$S/logs-full")"
printf '# edit\n' >>"$rrepo/apps/cyfr/lib/cyfr/a.ex"
RECEIPT_QUEUE_DEADLINE=1 rstage unqueued handoff
[ "$rc" = 1 ] || fail "a stage whose test rows never started exited $rc"
grep -qx 'selected unit sqlite apps/cyfr/test/cyfr/a_test.exs' "$S/logs-unqueued/receipt" &&
  grep -qx 'row unit: not run 75 [0-9]*s' "$S/logs-unqueued/receipt" &&
  ! grep -qE '^(tests|row unit: ok)' "$S/logs-unqueued/receipt" || fail "the unstarted row's receipt: $(cat "$S/logs-unqueued/receipt")"
git -C "$rrepo" checkout -q -- .

begin 'the real table reads whole, no save or handoff row takes more than one quarter, and every self-test a handoff row runs is one a pull-request workflow runs'
status=0; (cd "$ROOT" && scripts/stage.sh -n release) >"$S/real.out" 2>"$S/real.err" || status=$?
[ "$status" = 0 ] || fail "the real table was refused: $(cat "$S/real.err")"
grep -qF 'would run close (4 quarters): scripts/commit-gate.sh --close -l "$STAGE_LOGDIR/gate"' "$S/real.out" || fail "$(cat "$S/real.out")"
# What needs the whole machine is the pull request's run's: the save and
# handoff rows each queue for one quarter.
whole_rows() { # TABLE: prints each save or handoff row of TABLE on more than one quarter
  awk -F'\t' '!/^#/ && ($1 == "save" || $1 == "handoff") && $3 != "1" { print $1 "/" $2 }' "$1"
}
[ -z "$(whole_rows "$ROOT/scripts/stages.tsv")" ] || fail "a row takes the whole machine: $(whole_rows "$ROOT/scripts/stages.tsv" | tr '\n' ' ')"
{ cat "$ROOT/scripts/stages.tsv"; printf 'handoff\tprobe-one\t1\t60\t-\talways\ttrue\nhandoff\tprobe\t4\t60\t-\talways\ttrue\nsave\tprobe\t4\t60\t-\talways\ttrue\nrelease\tprobe\t4\t60\t-\talways\ttrue\n'; } >"$S/stages-whole.tsv"
[ "$(whole_rows "$S/stages-whole.tsv" | tr '\n' ' ')" = 'handoff/probe save/probe ' ] || fail "the whole-machine rows were not caught alone: $(whole_rows "$S/stages-whole.tsv")"
guard() { # TABLE [WORKFLOWS]: prints each self-test a handoff row of TABLE runs that no pull-request workflow runs
  python3 -I - "${2:-$ROOT/.github/workflows}" "$1" <<'PY'
import glob, os, re, sys, yaml
workflows, table = sys.argv[1:3]
rows = [line.rstrip("\n").split("\t") for line in open(table) if line.strip() and not line.startswith("#")]
handoff = [row[6] for row in rows if row[0] == "handoff"]
# A self-test is a script under tests/ that a command runs, named *-test.sh,
# *_test.py or *-test.exs (a command after `env` and its assignments
# counts, and `mix run` runs a script as elixir does); or a Python script
# under tests/ run with no argument, or with --self-check alone. A Python script given anything else
# (an image suite, given its image) is not one. A command counts only where
# the shell would run it, in a handoff row as in a workflow's step: comments
# and heredoc bodies are not read, and a script named among another
# command's arguments (echo's, a comment's) is not a command.
TEST_FILE = re.compile(r"tests/[\w./-]+?(?:-test\.sh|_test\.py|-test\.exs)")
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}", "time", "exec"}


def commands(text):
    """Each simple command of a shell script, as its words: quotes removed,
    comments and heredoc bodies left out, split at newlines, ;, &, &&, ||, |,
    ( and )."""
    out, words, word, heredocs = [], [], None, []
    i, n = 0, len(text)

    def end_word():
        nonlocal word
        if word is not None:
            words.append(word)
            word = None

    def end_command():
        end_word()
        if words:
            out.append(list(words))
            words.clear()

    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            if text[i + 1] != "\n":
                word = (word or "") + text[i + 1]
            i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            j = n if j < 0 else j
            word = (word or "") + text[i + 1:j]
            i = j + 1
        elif c == '"':
            j, buf = i + 1, ""
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf, j = buf + text[j + 1], j + 2
                else:
                    buf, j = buf + text[j], j + 1
            word = (word or "") + buf
            i = j + 1
        elif c == "#" and word is None:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "\n":
            end_command()
            i += 1
            for delimiter in heredocs:
                while i < n:
                    j = text.find("\n", i)
                    line = text[i:n if j < 0 else j]
                    i = n if j < 0 else j + 1
                    if line.strip() == delimiter:
                        break
            heredocs.clear()
        elif c in " \t":
            end_word()
            i += 1
        elif text.startswith("<<", i):
            end_word()
            i += 2
            if i < n and text[i] == "-":
                i += 1
            while i < n and text[i] in " \t":
                i += 1
            m = re.match(r"""['"]?([A-Za-z_]\w*)['"]?""", text[i:])
            if m:
                heredocs.append(m.group(1))
                i += m.end()
        elif text.startswith(("&&", "||"), i):
            end_command()
            i += 2
        elif c in ";|&()":
            end_command()
            i += 1
        else:
            word = (word or "") + c
            i += 1
    end_command()
    return out


def self_tests(words):
    """The self-test a simple command runs, as the guard names it, or none."""
    w = list(words)
    while w and (w[0] in RESERVED or w[0] == "env" or re.match(r"[A-Za-z_]\w*=", w[0])):
        w.pop(0)
    if not w:
        return []
    if w[:2] == ["mix", "run"]:
        w = ["elixir"] + w[2:]
    if w[0] in ("bash", "sh", "elixir", "python", "python3"):
        rest = w[1:]
        k = 0
        while k < len(rest) and rest[k].startswith("-"):
            if rest[k] in ("-c", "-m"):
                return []
            k += 1
        if k == len(rest):
            return []
        script, args = rest[k], rest[k + 1:]
    else:
        script, args = w[0], w[1:]
    script = script[2:] if script.startswith("./") else script
    if not script.startswith("tests/"):
        return []
    if TEST_FILE.fullmatch(script):
        return [script]
    if script.endswith(".py") and w[0] in ("python", "python3"):
        if args == []:
            return [script]
        if args == ["--self-check"]:
            return [script + " --self-check"]
    return []

ci = set()
for path in sorted(glob.glob(os.path.join(workflows, "*.yml"))):
    spec = yaml.safe_load(open(path))
    on = spec.get(True, spec.get("on")) or {}
    if "pull_request" not in on:
        continue
    for job in spec["jobs"].values():
        for step in job.get("steps", []):
            for command in commands(step.get("run") or ""):
                ci.update(self_tests(command))
local = {name for row in handoff for command in commands(row) for name in self_tests(command)}
print("\n".join(sorted(local - ci)))
PY
}
left=$(guard "$ROOT/scripts/stages.tsv")
[ -z "$left" ] || fail "a handoff row runs a self-test no pull-request workflow runs: $left"
# The control: a handoff row running a self-test no workflow runs is caught,
# a shell one, and a Python one run with --self-check alone or with no
# argument; a Python script given its image is no self-test.
probe_table() { # COMMAND: the real table with one more handoff row running COMMAND
  { cat "$ROOT/scripts/stages.tsv"; printf 'handoff\tprobe\t1\t60\t-\talways\t%s\n' "$1"; } >"$S/stages-probe.tsv"
}
probe_table 'bash tests/stage-probe-test.sh'
[ "$(guard "$S/stages-probe.tsv")" = tests/stage-probe-test.sh ] || fail "a row running a self-test no workflow runs was not caught: $(guard "$S/stages-probe.tsv")"
probe_table 'python3 -I tests/stage-probe.py --self-check && python3 -I tests/stage-probe_test.py'
[ "$(guard "$S/stages-probe.tsv")" = "$(printf '%s\n' 'tests/stage-probe.py --self-check' tests/stage-probe_test.py)" ] ||
  fail "a row running Python self-tests no workflow runs was not caught: $(guard "$S/stages-probe.tsv")"
probe_table 'env CYFR_DATABASE=sqlite MIX_ENV=dev mix run --no-start tests/stage-probe-test.exs'
[ "$(guard "$S/stages-probe.tsv")" = tests/stage-probe-test.exs ] || fail "a row running a script under mix run no workflow runs was not caught: $(guard "$S/stages-probe.tsv")"
probe_table 'python3 -I tests/stage-probe.py cyfr-locus:review'
[ -z "$(guard "$S/stages-probe.tsv")" ] || fail "an image suite given its image was counted as a self-test: $(guard "$S/stages-probe.tsv")"
# The roster tests are application tests, which the guard does not read:
# their row runs always, whatever a change touches, on one quarter.
rosters_held() { # TABLE: answers whether its rosters row runs both tests always on one quarter
  awk -F'\t' '$1 == "handoff" && $2 == "rosters" && $3 == "1" && $6 == "always" &&
    index($7, "apps/cyfr/test/cyfr/restore_order_test.exs") && index($7, "apps/cyfr/test/cyfr/cross_language_drift_test.exs") { held = 1 }
    END { exit !held }' "$1"
}
rosters_held "$ROOT/scripts/stages.tsv" || fail 'no handoff row runs the two roster tests always on one quarter'
grep -v $'^handoff\trosters\t' "$ROOT/scripts/stages.tsv" >"$S/stages-short.tsv"
! rosters_held "$S/stages-short.tsv" || fail 'a table without the rosters row was not caught'
sed $'/^handoff\trosters\t/s/\talways\t/\ttests\t/' "$ROOT/scripts/stages.tsv" >"$S/stages-short.tsv"
! rosters_held "$S/stages-short.tsv" || fail 'a rosters row that does not run always was not caught'
sed $'/^handoff\trosters\t/s/\t1\t/\t4\t/' "$ROOT/scripts/stages.tsv" >"$S/stages-short.tsv"
! rosters_held "$S/stages-short.tsv" || fail 'a rosters row on four quarters was not caught'
# A workflow runs a self-test where the shell runs it: not in a comment, an
# echo's arguments or a heredoc's body, and a real command with a comment
# after it, or after &&, does. An image suite given its image does not run
# its self-check.
planted() { # BODY: the workflows with one more pull-request step running BODY
  rm -rf "$S/workflows"; cp -r "$ROOT/.github/workflows" "$S/workflows"
  printf 'on: [pull_request]\njobs:\n  probe:\n    steps:\n      - run: |\n%s\n' "$(printf '%s\n' "$1" | sed 's/^/          /')" >"$S/workflows/probe.yml"
}
probe_table 'bash tests/stage-probe-test.sh'
for body in '# bash tests/stage-probe-test.sh' 'echo bash tests/stage-probe-test.sh' \
  $'python3 - <<\'EOF\'\nbash tests/stage-probe-test.sh\nEOF'; do
  planted "$body"
  [ "$(guard "$S/stages-probe.tsv" "$S/workflows")" = tests/stage-probe-test.sh ] || fail "counted as running the self-test: $body"
done
for body in 'bash tests/stage-probe-test.sh # a comment' $'set -e\ntrue && bash tests/stage-probe-test.sh'; do
  planted "$body"
  [ -z "$(guard "$S/stages-probe.tsv" "$S/workflows")" ] || fail "not counted as running the self-test: $body: $(guard "$S/stages-probe.tsv" "$S/workflows")"
done
probe_table 'python3 -I tests/stage-probe.py --self-check'
planted 'python3 -I tests/stage-probe.py cyfr-locus:review'
[ "$(guard "$S/stages-probe.tsv" "$S/workflows")" = 'tests/stage-probe.py --self-check' ] ||
  fail "an image suite given its image was counted as its self-check: $(guard "$S/stages-probe.tsv" "$S/workflows")"
planted 'python3 -I tests/stage-probe.py --self-check # no image'
[ -z "$(guard "$S/stages-probe.tsv" "$S/workflows")" ] ||
  fail "a self-check with a comment after it was not counted: $(guard "$S/stages-probe.tsv" "$S/workflows")"

begin "the Go rows' paths are their workflows' pull_request paths, and each new handoff row of the real table runs for its own sources alone"
python3 -I - "$ROOT/scripts/stages.tsv" "$ROOT/.github/workflows" >"$S/go-paths.err" 2>&1 <<'PY' || fail "$(cat "$S/go-paths.err")"
import sys, yaml
table, workflows = sys.argv[1:3]
rows = {f[1]: f[5] for f in (l.rstrip("\n").split("\t") for l in open(table)) if len(f) == 7 and f[0] == "handoff"}
for check, workflow in (("go-codex", "codex-ci.yml"), ("go-keeper", "keeper-ci.yml")):
    spec = yaml.safe_load(open(f"{workflows}/{workflow}"))
    paths = (spec.get("on") or spec.get(True))["pull_request"]["paths"]
    if rows.get(check, "").split(",") != paths:
        sys.exit(f"{check} runs for {rows.get(check)}, not {workflow}'s pull_request paths {','.join(paths)}")
PY
real="$S/real-repo"
git init -q -b main "$real"
mkdir -p "$real/scripts"
cp "$ROOT/scripts/stage.sh" "$ROOT/scripts/stages.tsv" "$real/scripts/"
git -C "$real" add -A
git -C "$real" -c user.name=test -c user.email=test@invalid commit -q -m 'the real table'
new_rows='go-codex go-keeper catalysts test-wasm locus-alone'
for spec in \
  'apps/codex/cmd/x.go|go-codex' \
  'seed/aqua/aqua.md|go-codex' \
  'apps/locus/keeper/main.go|go-keeper locus-alone' \
  'tests/fixtures/residue-canary.go|go-codex go-keeper' \
  'apps/locus/lib/locus/x.ex|locus-alone' \
  'stray.wasm|test-wasm' \
  'seed/components/catalysts/local/claude/1.4.3/src/src/chat.rs|catalysts' \
  'apps/cyfr/test/support/test_wasm/chat_fixture/chat_fixture.wasm|test-wasm' \
  'apps/prima/lib/prima/cargo_toml.ex|test-wasm' \
  'wit/catalyst/world.wit|test-wasm locus-alone' \
  'config/locus_runtime.exs|locus-alone' \
  'scripts/locus-island.sh|locus-alone' \
  'scripts/test-catalysts.sh|catalysts' \
  'mix.lock|' \
  'apps/prima/lib/prima/model.ex|' \
  'apps/cyfr/lib/cyfr/x.ex|'; do
  path=${spec%%|*} want=${spec#*|}
  git -C "$real" clean -qfdx
  mkdir -p "$(dirname "$real/$path")"
  echo change >"$real/$path"
  status=0; (cd "$real" && STAGE_BASE=HEAD scripts/stage.sh -n handoff) >"$S/real-rows.out" 2>"$S/real-rows.err" || status=$?
  [ "$status" = 0 ] || fail "a change to $path was refused: $(cat "$S/real-rows.err")"
  got=
  for check in $new_rows; do
    if grep -q "^would run $check " "$S/real-rows.out"; then got+="$check "; fi
  done
  [ "$got" = "${want:+$want }" ] || fail "a change to $path runs '${got% }', not '$want'"
done

begin 'the catalysts script tests every crate, stops at the first that fails with its status, and removes only the target folder it made'
cats="$S/catalysts"
mkdir -p "$cats/scripts" "$cats/bin" "$S/catalysts-tmp/kept"
cp "$ROOT/scripts/test-catalysts.sh" "$cats/scripts/"
for c in a b; do put "$cats/seed/components/catalysts/local/$c/1.0.0/src/src/chat.rs" '// chat'; done
cat >"$cats/bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "${PWD##*/local/} $*" >>"$CARGO_CALLS"
target=${!#}
mkdir -p "$target" && touch "$target/built"
exit "${CARGO_EXIT:-0}"
EOF
chmod +x "$cats/bin/cargo"
catalysts() { # NAME ARGS...: the script with the stand-in cargo; status to $rc
  local name=$1
  shift
  : >"$S/cargo-calls"
  rc=0
  (cd "$cats" && PATH="$cats/bin:$PATH" TMPDIR="$S/catalysts-tmp" CARGO_CALLS="$S/cargo-calls" scripts/test-catalysts.sh "$@") \
    >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
catalysts cats-pass
[ "$rc" = 0 ] && [ "$(cut -d' ' -f1 "$S/cargo-calls" | tr '\n' ' ')" = 'a/1.0.0/src b/1.0.0/src ' ] ||
  fail "a passing run exited $rc after: $(tr '\n' ';' <"$S/cargo-calls")"
[ "$(ls -A "$S/catalysts-tmp")" = kept ] || fail "the passing run left or removed: $(ls -A "$S/catalysts-tmp")"
CARGO_EXIT=3 catalysts cats-fail
[ "$rc" = 3 ] && [ "$(wc -l <"$S/cargo-calls")" = 1 ] && grep -qF 'a/1.0.0/src failed' "$S/cats-fail.err" ||
  fail "a failing crate gave $rc after: $(tr '\n' ';' <"$S/cargo-calls") $(cat "$S/cats-fail.err")"
[ "$(ls -A "$S/catalysts-tmp")" = kept ] || fail "the failing run left or removed: $(ls -A "$S/catalysts-tmp")"
catalysts cats-usage "$S/catalysts-tmp/kept"
[ "$rc" = 64 ] && [ -d "$S/catalysts-tmp/kept" ] && [ ! -s "$S/cargo-calls" ] || fail "a directory argument gave $rc"

begin "the Locus island script compiles and tests, in a folder of its own under TMPDIR that it removes alone, an island holding the lock, Locus, the deps and the WIT tree and no control plane"
isle="$S/island-repo"
mkdir -p "$isle/scripts" "$isle/bin" "$S/island-tmp/kept"
cp "$ROOT/scripts/locus-island.sh" "$isle/scripts/"
for f in mix.lock apps/prima/mix.exs apps/locus/mix.exs apps/cyfr/mix.exs deps/jason/mix.exs wit/catalyst/world.wit \
  _tools/wasm-tools tests/fixtures/toy_wire.json config/locus_runtime.exs; do
  put "$isle/$f" "$f"
done
cat >"$isle/bin/mix" <<'EOF'
#!/usr/bin/env bash
echo "${PWD#"$TMPDIR"/} ${MIX_ENV-} ${MIX_OS_CONCURRENCY_LOCK-} $*" >>"$MIX_CALLS"
# What the island holds when the compile starts: its top level and apps/.
[ "$1" != compile ] || (cd ../.. && { ls -A; ls -A apps | sed 's|^|apps/|'; }) >"$MIX_CALLS.tree"
EOF
chmod +x "$isle/bin/mix"
: >"$S/island-mix"
rc=0; (cd "$isle" && PATH="$isle/bin:$PATH" TMPDIR="$S/island-tmp" MIX_CALLS="$S/island-mix" scripts/locus-island.sh) >"$S/island.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "the island exited $rc: $(cat "$S/island.out")"
sed -E 's/^cyfr-locus-island\.[A-Za-z0-9]+/ISLAND/' "$S/island-mix" >"$S/island-mix.got"
printf '%s\n' 'ISLAND/apps/locus test 0 compile --warnings-as-errors' 'ISLAND/apps/locus test 0 test' >"$S/want"
diff "$S/want" "$S/island-mix.got" >/dev/null || fail "Mix ran as: $(tr '\n' ';' <"$S/island-mix")"
[ "$(ls -A "$S/island-tmp")" = kept ] || fail "the island left or removed: $(ls -A "$S/island-tmp")"
for want in mix.lock apps/locus deps wit; do
  grep -qx "$want" "$S/island-mix.tree" || fail "the island lacks $want: $(tr '\n' ' ' <"$S/island-mix.tree")"
done
! grep -qx apps/cyfr "$S/island-mix.tree" || fail "the island holds the control plane: $(tr '\n' ' ' <"$S/island-mix.tree")"
rc=0; (cd "$isle" && scripts/locus-island.sh "$S/island-tmp/kept") >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] && [ -d "$S/island-tmp/kept" ] || fail "a directory argument gave $rc"
rm -r "$isle/_tools"
rc=0; (cd "$isle" && TMPDIR="$S/island-tmp" scripts/locus-island.sh) >"$S/island-missing.err" 2>&1 || rc=$?
[ "$rc" = 69 ] && grep -qF '_tools is missing' "$S/island-missing.err" || fail "a missing _tools gave $rc: $(cat "$S/island-missing.err")"

begin "the real table's nightly runs the janitor, install and handle on one quarter, then both reference canvas viewports on four, one after another"
status=0; (cd "$ROOT" && scripts/stage.sh -n nightly) >"$S/nightly-real.out" 2>"$S/nightly-real.err" || status=$?
[ "$status" = 0 ] || fail "the nightly stage was refused: $(cat "$S/nightly-real.err")"
grep -qxF 'would run janitor (1 quarter): scripts/janitor.sh' "$S/nightly-real.out" &&
  grep -qx 'would run install-screen-proof (1 quarter): .* && tests/install-screen-proof/run.sh' "$S/nightly-real.out" &&
  grep -qxF 'would run handle-proof (1 quarter): tests/handle-proof/run.sh' "$S/nightly-real.out" ||
  fail "the nightly would run: $(cat "$S/nightly-real.out")"
for viewport in desktop 720x720; do
  grep -qxF "would run canvas-proof-$viewport (4 quarters): env CANVAS_PROOF_HOST_CLASS=reference CANVAS_PROOF_VIEWPORT=$viewport PROOF_OUT=\"\$STAGE_LOGDIR/canvas/$viewport\" tests/canvas-proof/run.sh" "$S/nightly-real.out" ||
    fail "the nightly does not run the reference canvas proof at $viewport on the whole machine with its records kept: $(cat "$S/nightly-real.out")"
done
# The report's grammar holds no skipped row: every nightly row runs always.
selected=$(awk -F'\t' '!/^#/ && $1 == "nightly" && $6 != "always" { print $2 }' "$ROOT/scripts/stages.tsv")
[ -z "$selected" ] || fail "a nightly row has a selector: $selected"
# The nightly runs its rows one after another in the table's order, as
# every stage but save and handoff does, the janitor before the proofs: a
# stand-in queue records each row's start and end and runs nothing.
[ "$(awk -F'\t' '!/^#/ && $1 == "nightly" { print $2 }' "$ROOT/scripts/stages.tsv" | tr '\n' ' ')" = 'janitor install-screen-proof handle-proof canvas-proof-desktop canvas-proof-720x720 ' ] ||
  fail 'the nightly does not hold the janitor, then the install-screen and handle proofs, then both canvas viewports'
night="$S/night-repo"
git init -q -b main "$night"
mkdir -p "$night/scripts"
cp "$ROOT/scripts/stage.sh" "$ROOT/scripts/stages.tsv" "$night/scripts/"
cat >"$night/scripts/heavy-check.sh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
printf 'start %s\n' "$4" >>"$NIGHT_EVENTS"
sleep 0.3
printf 'end %s\n' "$4" >>"$NIGHT_EVENTS"
EOF
chmod +x "$night/scripts/heavy-check.sh"
git -C "$night" add -A
git -C "$night" -c user.name=test -c user.email=test@invalid commit -q -m 'the real table'
: >"$S/night-events"
status=0; (cd "$night" && NIGHT_EVENTS="$S/night-events" scripts/stage.sh -l "$S/logs-night-order" nightly) >"$S/night-order.out" 2>&1 || status=$?
[ "$status" = 0 ] || fail "the nightly's stand-in run exited $status: $(cat "$S/night-order.out")"
awk -F'\t' '!/^#/ && $1 == "nightly" { print "start " $7; print "end " $7 }' "$ROOT/scripts/stages.tsv" >"$S/want"
diff "$S/want" "$S/night-events" >/dev/null || fail "the nightly's rows ran as: $(cut -c1-40 "$S/night-events" | tr '\n' ';')"

echo 'stage tests passed'

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/stage.sh against a toy repository with a toy table and a stand-in
# scripts/heavy-check.sh that records each call and runs its command (a
# command holding `#queue-deadline` is answered 75, as a queue deadline is);
# scripts/lib/nightly.py's flakes and weights on planted run directories;
# and the real table, read whole by the real scripts/stage.sh and held to
# every self-test command a pull-request workflow runs. It needs git,
# python3 with PyYAML, and no Docker, database or build.
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
cp "$ROOT/scripts/stage.sh" "$repo/scripts/"
cat >"$repo/scripts/heavy-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$*" in *'#queue-deadline'*) exit 75 ;; esac
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
chmod +x "$repo/scripts/heavy-check.sh"
export STUB_CALLS="$S/calls"
for f in apps/arca/lib/arca/x.ex apps/arca/test/arca/x_test.exs apps/cyfr/lib/cyfr/a.ex apps/cyfr/test/cyfr/a_test.exs \
  apps/cyfr/lib/cyfr/no_mirror.ex apps/cyfr/lib/cyfr/gone.ex apps/cyfr/test/cyfr/gone_test.exs apps/cyfr/test/cyfr/old_test.exs \
  apps/cyfr/lib/cluster/k.ex apps/cyfr/test/cluster/k_test.exs apps/cyfr/test/cluster/c_test.exs docs/notes.md README.md; do
  put "$repo/$f" "$f"
done
toy_rows=(
  'handoff|format|none|-|always|git grep -q . -- README.md'
  'handoff|compile|scoped|60|apps/**,config/**|echo compile'
  'handoff|dialyzer|scoped|60|apps/*/lib/**|echo dialyzer'
  'handoff|arca|scoped|60|apps/arca/**|echo arca'
  'handoff|tests|scoped|60|tests|printf "%s\n" $STAGE_TESTS >"$STAGE_LOGDIR/tests.txt"'
  'handoff|env|proof|60|always|printf "%s;%s;%s;%s\n" "$STAGE" "$STAGE_TESTS" "$STAGE_LOGDIR" "${PROOF_RUN_PREFIX-unset}" >"$STAGE_LOGDIR/env.txt"'
  'handoff|docs|exclusive|60|docs/**|echo docs'
  'release|close|exclusive|60|always|echo close'
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

begin 'every row of a stage runs or is skipped by its when, in its lane, with the stage environment'
reset_tree
printf '# edit\n' >>"$repo/apps/cyfr/lib/cyfr/a.ex"
stage run -l "$S/logs-run" handoff
[ "$rc" = 0 ] || fail "exited $rc: $(cat "$S/run.err")"
framed run 0
sed -n '2,$p' "$S/run.out" | sed '$d' | sed -E 's/ [0-9]+s$//' >"$S/got"
printf '%s\n' 'format: ok' 'compile: ok' 'dialyzer: ok' 'arca: skipped (no changed path matches apps/arca/**)' \
  'tests: ok' 'env: ok' 'docs: skipped (no changed path matches docs/**)' >"$S/want"
diff "$S/want" "$S/got" >/dev/null || fail "the rows said: $(tr '\n' ';' <"$S/got")"
[ "$(cat "$S/logs-run/tests.txt")" = apps/cyfr/test/cyfr/a_test.exs ] || fail "STAGE_TESTS: $(cat "$S/logs-run/tests.txt")"
[ "$(cat "$S/logs-run/env.txt")" = "handoff;apps/cyfr/test/cyfr/a_test.exs;$S/logs-run;unset" ] ||
  fail "the row environment: $(cat "$S/logs-run/env.txt")"
grep -qx 'compile' "$S/logs-run/compile.log" || fail 'a row log does not hold its output'
grep -qx -- '-s -t 60 -- bash -c echo compile' "$STUB_CALLS" || fail "a scoped row did not queue -s -t 60: $(cat "$STUB_CALLS")"
grep -q -- '^-p -t 60 -- bash -c printf' "$STUB_CALLS" || fail 'a proof row did not queue -p'
if grep -q 'git grep' "$STUB_CALLS"; then fail 'a none row went through heavy-check'; fi
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

begin 'a deleted lib file alone selects the compile, dialyzer and Arca rows and puts its mirror test, never itself, in the list'
reset_tree
rm "$repo/apps/arca/lib/arca/x.ex"
stage deleted -n handoff
[ "$rc" = 0 ] || fail "exited $rc"
for check in compile dialyzer arca tests; do grep -q "^would run $check " "$S/deleted.out" || fail "$check would not run"; done
grep -q '^would skip docs: ' "$S/deleted.out" || fail 'docs would run'
stage deleted-run -l "$S/logs-deleted" handoff
[ "$(cat "$S/logs-deleted/tests.txt")" = apps/arca/test/arca/x_test.exs ] || fail "the touched tests: $(cat "$S/logs-deleted/tests.txt")"
if grep -q 'lib/arca/x.ex' "$S/logs-deleted/tests.txt"; then fail 'the deleted file reached the test paths'; fi

begin 'a deleted test is absent from the list, and an empty change set skips every path and tests row while format runs'
reset_tree
rm "$repo/apps/cyfr/test/cyfr/old_test.exs"
stage deleted-test -l "$S/logs-deleted-test" handoff
grep -qx 'tests: skipped (no touched test)' "$S/deleted-test.out" || fail "the deleted test was handed on: $(cat "$S/deleted-test.out")"
reset_tree
stage clean -l "$S/logs-clean" handoff
[ "$rc" = 0 ] || fail "exited $rc"
grep -qx 'format: ok [0-9]*s' "$S/clean.out" || fail 'format did not run'
grep -qx 'tests: skipped (no touched test)' "$S/clean.out" || fail 'the tests row ran with no touched test'
for check in compile dialyzer arca docs; do grep -q "^$check: skipped (no changed path matches" "$S/clean.out" || fail "$check ran"; done

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

begin 'a row whose queue deadline passes fails, and the rows after it still run'
table "${toy_rows[@]}" 'release|queue|scoped|60|always|echo #queue-deadline' 'release|after|scoped|60|always|echo after'
stage deadline -l "$S/logs-deadline" release
[ "$rc" = 1 ] || fail "exited $rc, not 1"
framed deadline 1
grep -qx 'queue: failed 75 [0-9]*s' "$S/deadline.out" || fail "the deadline row said: $(cat "$S/deadline.out")"
grep -qx 'after: ok [0-9]*s' "$S/deadline.out" || fail 'the row after it did not run'
table "${toy_rows[@]}"

begin 'a dry run names each row and runs nothing'
reset_tree
printf '# edit\n' >>"$repo/docs/notes.md"
stage dry -n handoff
[ "$rc" = 0 ] || fail "exited $rc"
framed dry 0
grep -qxF 'would run docs (exclusive): echo docs' "$S/dry.out" || fail "$(cat "$S/dry.out")"
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
refused 9 "no stage is called 'deploy'" 'deploy|x|scoped|60|always|echo x'
refused 9 "no lane is called 'fast'" 'nightly|x|fast|60|always|echo x'
refused 9 "'apps/**,,config/**' is not always, tests or comma-separated globs" 'handoff|x|scoped|60|apps/**,,config/**|echo x'
refused 9 "'apps/** config/**' is not always, tests or comma-separated globs" 'handoff|x|scoped|60|apps/** config/**|echo x'
refused 9 'handoff has a second check called compile' 'handoff|compile|scoped|60|always|echo x'
refused 9 'only save and handoff rows take tests' 'release|x|scoped|60|tests|echo x'
refused 9 'only save and handoff rows take globs' 'nightly|x|scoped|60|apps/**|echo x'
refused 9 'the none lane runs only mix format --check-formatted and git grep, not: mix test' 'handoff|x|none|-|always|mix test'
refused 9 'a row in the none lane holds nothing: its hold is -' 'handoff|x|none|60|always|git grep x'
refused 9 "the hold '-' is not seconds" 'handoff|x|scoped|-|always|echo x'
refused 9 "the check 'Compile' is not [a-z0-9-]+" 'handoff|Compile|scoped|60|always|echo x'
refused 9 'a row has six fields separated by single tabs' 'handoff|x|scoped|60|echo x'
refused 9 'a field is empty' 'handoff||scoped|60|always|echo x'
table "${toy_rows[@]}"

begin 'inside a heavy-check it exits 64 unframed, and outside a checkout 69'
status=0; (cd "$repo" && HEAVY_CHECK_HELD=scoped scripts/stage.sh -n handoff) >"$S/held.out" 2>&1 || status=$?
[ "$status" = 64 ] || fail "inside a heavy-check: $status"
if grep -q '^_START=' "$S/held.out"; then fail 'a refusal inside a heavy-check wrote a frame'; fi
mkdir -p "$S/loose/scripts"
cp "$ROOT/scripts/stage.sh" "$S/loose/scripts/"
status=0; "$S/loose/scripts/stage.sh" -n handoff >"$S/loose.out" 2>"$S/loose.err" || status=$?
[ "$status" = 69 ] && grep -qF 'is not inside a git checkout' "$S/loose.err" || fail "outside a checkout: $status $(cat "$S/loose.err")"
status=0; (cd "$repo" && scripts/stage.sh -n deploy) >/dev/null 2>&1 || status=$?
[ "$status" = 64 ] || fail "an unknown stage gave $status"

begin 'INT and TERM stop the running row and end with a frame'
table "${toy_rows[@]}" 'release|slow|scoped|60|always|exec sleep 6107'
for sig in INT:130 TERM:143; do
  name=${sig%%:*} want=${sig##*:}
  : >"$STUB_CALLS"
  (cd "$repo" && exec "${defaulted[@]}" INT scripts/stage.sh -l "$S/logs-$name" release) >"$S/$name.out" 2>&1 &
  runner=$!
  until_true 10 grep -q 'sleep 6107' "$STUB_CALLS" || fail "$name: the slow row never started"
  until_true 10 pgrep -f '^sleep 6107$' >/dev/null || fail "$name: no sleep found"
  sleeper=$(pgrep -f '^sleep 6107$' | head -1)
  [ -n "$sleeper" ] || fail "$name: no sleep found"
  kill -"$name" "$runner"
  status=0; wait "$runner" || status=$?
  [ "$status" = "$want" ] || fail "$name: exited $status, not $want"
  grep -qx "_EXIT=$runner $want" "$S/$name.out" || fail "$name: the last line is $(tail -n 1 "$S/$name.out")"
  until_true 10 eval '! kill -0 "$sleeper"' || fail "$name: the row's command outlived the stage"
done
table "${toy_rows[@]}"

begin 'flakes: failing in both, flaky in one, and unknown for an incomplete partition, an exit of 3 and exclusions in one run only'
night="$S/night"
mkdir -p "$night"
# plant LOG-NAME RUN-DIR EXIT1 EXIT2 EXIT3: a suite row's log over three
# partitions, holding the Arca test, then Cyfr's b and c tests.
plant() {
  {
    echo '_START=1'
    for i in 1 2 3; do
      echo "==> partition $i/3"
      eval "status=\${$((i + 2))}"
      [ "$status" = 0 ] || printf '    partition exited %s; its account:\n' "$status"
    done
    echo "==> logs and disposable resources kept: $2"
    echo '_EXIT=1 1'
  } >"$night/$1.log"
  mkdir -p "$2/assign"
  printf 'apps/arca/test/a_test.exs\0' >"$2/assign/p1"
  printf 'apps/cyfr/test/b_test.exs\0' >"$2/assign/p2"
  printf 'apps/cyfr/test/c_test.exs\0' >"$2/assign/p3"
}
failure() { printf '  %s) test %s (%s)\n     %s:7\n' "$1" "$2" "$3" "$4"; }
plant sqlite-1 "$S/run-s1" 0 2 2
plant sqlite-2 "$S/run-s2" 0 2 0
printf '==> arca\nResult: 3 passed\n' >"$S/run-s1/p1.log"
{ echo '==> cyfr'; failure 1 'fails always' Cyfr.BTest test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-s1/p2.log"
{ echo '==> cyfr'; failure 1 'fails once' Cyfr.CTest test/c_test.exs; echo 'Result: 1/2 passed'; } >"$S/run-s1/p3.log"
printf '==> arca\nResult: 3 passed\n' >"$S/run-s2/p1.log"
{ echo '==> cyfr'; failure 1 'fails always' Cyfr.BTest test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-s2/p2.log"
printf '==> cyfr\nResult: 2 passed\n' >"$S/run-s2/p3.log"
# postgres-2 fails three tests; postgres-1 cannot vouch for any of them:
# its Arca partition never wrote Arca's Result line, its b partition
# exited 3 (failures and warnings), and its c partition excluded none where
# postgres-2's excluded one.
plant postgres-2 "$S/run-p2" 2 2 2
{ echo '==> arca'; failure 1 'cut short' Arca.ATest test/a_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-p2/p1.log"
{ echo '==> cyfr'; failure 1 'warned' Cyfr.BTest test/b_test.exs; echo 'Result: 2/3 passed'; } >"$S/run-p2/p2.log"
{ echo '==> cyfr'; failure 1 'excluded elsewhere' Cyfr.CTest test/c_test.exs; echo 'Result: 1/2 passed, 1 excluded'; } >"$S/run-p2/p3.log"
plant postgres-1 "$S/run-p1" 0 3 0
printf '==> arca\n' >"$S/run-p1/p1.log"
printf '==> cyfr\nResult: 3 passed\n' >"$S/run-p1/p2.log"
printf '==> cyfr\nResult: 2 passed\n' >"$S/run-p1/p3.log"
python3 -I "$ROOT/scripts/lib/nightly.py" flakes "$night" >"$S/flakes.txt"
printf '%s\n' \
  $'failing\tsqlite\tcyfr\tfails always (Cyfr.BTest)\tfailed in sqlite-1 and sqlite-2' \
  $'flaky\tsqlite\tcyfr\tfails once (Cyfr.CTest)\tfailed in sqlite-1' \
  $'unknown\tpostgres\tarca\tcut short (Arca.ATest)\tfailed in postgres-2' \
  $'unknown\tpostgres\tcyfr\texcluded elsewhere (Cyfr.CTest)\tfailed in postgres-2' \
  $'unknown\tpostgres\tcyfr\twarned (Cyfr.BTest)\tfailed in postgres-2' | LC_ALL=C sort >"$S/want"
LC_ALL=C sort "$S/flakes.txt" | diff "$S/want" - >/dev/null || fail "the verdicts: $(cat "$S/flakes.txt")"
# The positive control: postgres-1 whole, exiting 0, with the same
# exclusions, makes all three flaky.
plant postgres-1 "$S/run-p1" 0 0 0
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

begin 'the real table reads whole, and has a handoff row for every self-test a pull-request workflow runs'
status=0; (cd "$ROOT" && scripts/stage.sh -n release) >"$S/real.out" 2>"$S/real.err" || status=$?
[ "$status" = 0 ] || fail "the real table was refused: $(cat "$S/real.err")"
grep -qF 'would run close (exclusive): scripts/commit-gate.sh --close -l "$STAGE_LOGDIR/gate"' "$S/real.out" || fail "$(cat "$S/real.out")"
guard() { # TABLE: prints each self-test command no handoff row of TABLE runs
  python3 -I - "$ROOT/.github/workflows" "$1" <<'PY'
import glob, os, re, sys, yaml
workflows, table = sys.argv[1:3]
rows = [line.rstrip("\n").split("\t") for line in open(table) if line.strip() and not line.startswith("#")]
handoff = [row[5] for row in rows if row[0] == "handoff"]
# A self-test is a script under tests/ named *-test.sh, *_test.py or
# *-test.exs, or any tests/ script given --self-check.
test_file = re.compile(r"(?<![\w/.-])(tests/[\w./-]+?(?:-test\.sh|_test\.py|-test\.exs))(?![\w./-])")
self_check = re.compile(r"(?<![\w/.-])(tests/[\w./-]+\.py)\s+--self-check")
missing = set()
for path in sorted(glob.glob(os.path.join(workflows, "*.yml"))):
    spec = yaml.safe_load(open(path))
    on = spec.get(True, spec.get("on")) or {}
    if "pull_request" not in on:
        continue
    for job in spec["jobs"].values():
        for step in job.get("steps", []):
            run = step.get("run") or ""
            for name in test_file.findall(run):
                if not any(re.search(r"(?<![\w/.-])" + re.escape(name) + r"(?![\w./-])", c) for c in handoff):
                    missing.add(name)
            for name in self_check.findall(run):
                if not any(re.search(re.escape(name) + r"\s+--self-check", c) for c in handoff):
                    missing.add(name + " --self-check")
print("\n".join(sorted(missing)))
PY
}
left=$(guard "$ROOT/scripts/stages.tsv")
[ -z "$left" ] || fail "no handoff row runs: $left"
grep -v $'^handoff\tcontain-test\t' "$ROOT/scripts/stages.tsv" >"$S/stages-short.tsv"
[ "$(guard "$S/stages-short.tsv")" = tests/contain-test.sh ] || fail "a table without the contain-test row was not caught: $(guard "$S/stages-short.tsv")"

echo 'stage tests passed'

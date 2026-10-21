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
REAL_MIX=$(command -v mix) || fail 'no Mix on PATH for the fixtures recipe the stand-in hands on'
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
    [ "${MIX_OS_CONCURRENCY_LOCK:-}" = 0 ] || echo "$PWD $1" >> "$TRACE/island-with-build-lock"
    # What the island holds: its top level, and what apps/, config/,
    # tests/ and seed/ hold.
    [ "$1" != compile ] || (cd ../.. && { ls -A; for d in apps config tests seed; do [ ! -d "$d" ] || ls -A "$d" | sed "s|^|$d/|"; done; } | LC_ALL=C sort) > "$TRACE/island.$app.tree" ;;
  *) key="${CYFR_DATABASE:-none}_${MIX_ENV:-dev}_$1" ;;
esac
# The Rust test fixtures' recipe writes each fixture's Cargo.toml with
# `MIX_ENV=test mix run --no-start -e ...` (build-fixture.sh), which the
# gate's check of the test WASM fixtures runs: the real Mix answers it,
# its build lock in a directory of the trace's rather than the case's
# TMPDIR, which a case holds to what the gate itself leaves there.
if [ "$1" = run ] && [ "${2:-}" = --no-start ] && [ "${3:-}" = -e ] && [ -n "${CARGO_TOML:-}" ]; then
  mkdir -p "$TRACE/real-mix-tmp"
  TMPDIR="$TRACE/real-mix-tmp" exec "$REAL_MIX" "$@"
fi
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
    TRACE="$scratch/$name.trace" PATH="$scratch/bin:$PATH" REAL_MIX="$REAL_MIX" CYFR_DATABASE_URL='postgres://u:p@host/base' \
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

# --- what the gate leaves out ------------------------------------------------
# ci_roster GATE WORKFLOWS: every step of every workflow a pull request
# runs is one of four things, and nothing else: run by a step of the gate
# (CI_RUNS below, each naming gate steps the gate has), named on the gate's
# "Not part of this gate" list (a job there covers every step of it),
# setup that checks nothing, or a report of a failed job. One rule makes a
# step setup, named or not: it uses a listed action (SETUP_ACTIONS), or
# every command its script runs is a listed setup command (SETUP_COMMANDS),
# so a setup step that gains a check is no longer setup. A step whose `if:`
# is false whenever its job has not failed runs only once it has, so it
# cannot decide a pass: a report. Its condition is `failure()` alone or
# `failure() && REST`, REST holding no `||` and no other status function,
# so the whole is a conjunction with failure() in it; any other condition,
# `failure() && x || success()` among them, makes no report. A list entry, a run, a setup action or a
# setup command that matches no step fails too, so the list is the
# workflows' exactly. A step is keyed by its name, or unnamed by
# `uses: ACTION` or by its whole script, `run: LINE; LINE…`. release.yml
# runs on a tag alone, and its checks are these workflows, which it calls.
ci_roster() {
  python3 -I - "$1" "$2" <<'PY'
import glob, os, re, sys, yaml

gate_path, wf_dir = sys.argv[1], sys.argv[2]
gate = open(gate_path).read()
lines = gate.split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("# Not part of this gate"))
roster = {}
for l in lines[start + 1:]:
    if l.startswith("# Without -n"):
        break
    m = re.fullmatch(r"#   (\S+\.yml) ([a-z0-9_-]+)(?:: (.+))?", l)
    if m:
        roster[(m[1], m[2], m[3])] = 0
have = set(re.findall(r"\bstep (?:static|postgres|vocab|cluster) ([a-z_]+)", gate))
have |= {"islands:" + a for m in re.findall(r"^\s*run_islands ([a-z ]+)", gate, re.M) for a in m.split()}

CI_RUNS = {
    ("dialyzer.yml", "dialyzer", "run: mix compile --warnings-as-errors"): ["compile_sqlite_dev"],
    ("dialyzer.yml", "dialyzer", "Build PLT"): ["dialyzer"],
    ("dialyzer.yml", "dialyzer", "Dialyzer"): ["dialyzer"],
    ("test.yml", "static", "Install the pinned wasm-tools"): ["wasm_tools"],
    ("test.yml", "static", "Compile with warnings as errors"): ["compile_sqlite_test"],
    ("test.yml", "static", "Boundary plants"): ["boundary_plants"],
    ("test.yml", "static", "Static analysis"): ["credo"],
    ("test.yml", "static", "Check formatting"): ["format"],
    ("test.yml", "static", "The CLI catalog is the operation table's"): ["opsgen"],
    ("test.yml", "static", "The configuration guide is the roster's"): ["confguide"],
    ("test.yml", "static", "The built SDK is its source's"): ["sdk_bundle"],
    ("test.yml", "static", "The built toolkit is its source's"): ["toolkit_bundle"],
    ("test.yml", "static", "Every test WASM fixture is its source's build"): ["test_wasm"],
    ("test.yml", "static", "The image suites' shared plumbing"): ["imagesuite_checks"],
    ("test.yml", "js-unit", "Install the lint and coverage tools"): ["eslint"],
    ("test.yml", "js-unit", "Lint the console's JavaScript and the SDK"): ["eslint"],
    ("test.yml", "js-unit", "The console's JavaScript tests (the SDK, the canvas toolkit, the canvas, the carrier, the system layer and the markdown hook's parse step)"): ["js_suite"],
    ("test.yml", "test", "Install the pinned wasm-tools"): ["wasm_tools"],
    ("test.yml", "test", "Compile with warnings as errors"): ["compile_sqlite_test", "compile_pg_test"],
    ("test.yml", "test", "Compile the dev target with warnings as errors"): ["compile_sqlite_dev", "compile_pg_dev"],
    ("test.yml", "test", "Run tests"): ["sqlite_suite", "pg_tests", "pg_suite"],
    ("test.yml", "cluster", "Compile with warnings as errors"): ["compile_pg_test"],
    ("test.yml", "cluster", "Run the two-node suite"): ["cluster"],
    ("test.yml", "prima-independence", "Compile and test Prima alone"): ["islands:prima"],
    ("test.yml", "arca-independence", "Compile and test Arca from its declared apps alone"): ["islands:arca"],
    ("test.yml", "sanctum-independence", "Compile and test Sanctum from its declared apps alone"): ["islands:sanctum"],
    ("test.yml", "locus-independence", "Compile and test Locus from its declared apps alone"): ["islands:locus"],
    ("test.yml", "locus-runtime-image", "The credential canary's own checks"): ["canary_checks"],
    ("test.yml", "release-boot", "Each run names and drops databases of its own"): ["boot_names"],
    ("test.yml", "vocabulary-gate", "Retired names stay out and the storage layout is Arca's"): ["fossils"],
}
SETUP_ACTIONS = {
    "actions/checkout", "actions/setup-node", "actions/setup-go", "./.github/actions/setup-elixir", "actions/cache",
    "actions/upload-artifact", "actions/download-artifact",
}
# Each a whole command, as the script spells it with its continuations
# joined: installs, a container started for a suite, a wait for it, an
# image loaded and tagged.
SETUP_COMMANDS = [
    r"set -euo pipefail",
    r"mix deps\.get",
    r"sudo scripts/ci/containerd-image-store\.sh",
    r"rustup (?:target add|toolchain install) [^;&|<>`$()]*(?:\"\$[A-Z_]+\"[^;&|<>`()]*)*",
    r'if \[ "\$CACHE_HIT" != "true" \]; then',
    r'cargo install cargo-component --version "\$CARGO_COMPONENT_VERSION" --locked',
    r"cargo-component --version",
    r"docker run -d --name minio [^;&|<>`$()]*",
    r"for i in \$\(seq 1 \d+\); do",
    r"curl -sf http://127\.0\.0\.1:9000/minio/health/live && exit 0",
    r"sleep \d+",
    r'echo "MinIO did not become healthy" >&2',
    r"docker logs minio \|\| true",
    r"exit 1",
    r'zstd -dc "\$RUNNER_TEMP/locus-image/cyfr-locus\.tar\.zst" \| docker load',
    r"docker tag cyfr-locus:ci cyfr-locus:[a-z-]+",
]
SHAPE = {"then", "else", "fi", "do", "done", "{", "}"}

# The commands of a script: its lines with continuations joined, less blank
# lines, comments, a heredoc's body and the words that only shape it.
def commands(script):
    out, joined, heredoc = [], "", None
    for line in script.split("\n"):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        if line.endswith("\\"):
            joined += line[:-1].strip() + " "
            continue
        line, joined = (joined + line.strip()).strip(), ""
        if not line or line.startswith("#") or line in SHAPE:
            continue
        m = re.search(r"<<-?\s*'?([A-Za-z_]+)'?", line)
        if m:
            heredoc = m.group(1)
        out.append(line)
    return out

setup_used = set()
def unlisted(s):
    """The commands of a run step that are no setup command, or None for a
    step that uses an action: [] for setup."""
    if "uses" in s:
        action = s["uses"].split("@")[0]
        if action in SETUP_ACTIONS:
            setup_used.add(action)
            return []
        return [action]
    left = []
    for c in commands(s["run"]):
        hit = next((p for p in SETUP_COMMANDS if re.fullmatch(p, c)), None)
        if hit is None:
            left.append(c)
        else:
            setup_used.add(hit)
    return left

def report(s):
    cond = str(s.get("if", "")).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    cond = (m.group(1) if m else cond).strip()
    m = re.fullmatch(r"failure\(\)(?:\s*&&(.*))?", cond, re.S)
    if m is None:
        return False
    rest = m.group(1) or ""
    return "||" not in rest and re.search(r"\b(?:success|always|cancelled|failure)\s*\(", rest) is None

def key(s):
    if s.get("name"):
        return s["name"]
    if "uses" in s:
        return "uses: " + s["uses"].split("@")[0]
    lines = [l.strip() for l in s["run"].strip().split("\n") if l.strip()]
    return "run: " + "; ".join(lines)

errors, runs_seen = [], set()
for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml"))):
    wf = os.path.basename(path)
    spec = yaml.safe_load(open(path))
    on = spec.get(True, spec.get("on")) or {}
    if "pull_request" not in on:
        continue
    for job, body in spec["jobs"].items():
        if (wf, job, None) in roster:
            roster[(wf, job, None)] += 1
            continue
        for s in body.get("steps", []):
            k = key(s)
            where = []
            if (wf, job, k) in roster:
                roster[(wf, job, k)] += 1
                where.append("the list")
            if (wf, job, k) in CI_RUNS:
                runs_seen.add((wf, job, k))
                where.append("a gate step")
            left = unlisted(s)
            if not where and report(s):
                where.append("a report")
            elif not where and left == []:
                where.append("setup")
            if len(where) != 1:
                why = f" (it runs {', '.join(map(repr, left))}, no setup command)" if not where and left else ""
                errors.append(f"{wf} {job}: {k!r} is " + (" and ".join(where) if where else
                              "neither run by the gate nor on its list") + why)
for (wf, job, k), n in roster.items():
    if n == 0:
        errors.append(f"the list names {wf} {job}" + (f": {k}" if k else "") + ", which no pull request runs")
for entry, names in CI_RUNS.items():
    if entry not in runs_seen:
        errors.append(f"the test's run map names {entry}, which no pull request runs")
    errors += [f"the test's run map names the gate step {n}, which the gate has not" for n in names if n not in have]
errors += [f"the test's setup names {k!r}, which no step is"
           for k in sorted(SETUP_ACTIONS - setup_used) + [p for p in SETUP_COMMANDS if p not in setup_used]]
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}
ci_roster "$gate" "$root/.github/workflows" || fail "the gate's exclusion list is not CI's checks less the gate's"
# Planted: a check added to CI, unnamed behind a setup command, a named
# setup step that gains a check, a check whose condition also runs on a
# job that has not failed, a job taken off the list, and a list entry CI
# no longer has each fail it, with the reason.
mkdir -p "$scratch/roster/wf"
cp "$root"/.github/workflows/*.yml "$scratch/roster/wf/"
python3 -I - "$scratch/roster/wf/test.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "      - name: Retired names stay out and the storage layout is Arca's\n"
assert anchor in s
open(p, "w").write(s.replace(anchor, "      - name: A planted check\n        run: \"true\"\n" + anchor))
PY
! ci_roster "$gate" "$scratch/roster/wf" 2>"$scratch/roster/added.err" || fail 'a CI check neither run by the gate nor on its list passed'
has_line "'A planted check' is neither run by the gate nor on its list" "$scratch/roster/added.err" ||
  fail "an added CI check failed without its reason: $(cat "$scratch/roster/added.err")"
mkdir -p "$scratch/roster/unnamed"
cp "$root"/.github/workflows/*.yml "$scratch/roster/unnamed/"
python3 -I - "$scratch/roster/unnamed/test.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "      - name: Compile with warnings as errors\n"
assert anchor in s
step = "      - run: |\n          mix deps.get\n          test -f newly-required-ci-asset\n"
open(p, "w").write(s.replace(anchor, step + anchor, 1))
PY
! ci_roster "$gate" "$scratch/roster/unnamed" 2>"$scratch/roster/unnamed.err" ||
  fail 'an unnamed CI check behind a setup command passed as setup'
has_line "^test.yml static: 'run: mix deps.get; test -f newly-required-ci-asset' is neither run by the gate nor on its list" \
  "$scratch/roster/unnamed.err" || fail "an unnamed CI check failed without its reason: $(cat "$scratch/roster/unnamed.err")"
mkdir -p "$scratch/roster/named"
cp "$root"/.github/workflows/*.yml "$scratch/roster/named/"
python3 -I - "$scratch/roster/named/test.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
setup = "      - name: Install dependencies\n        run: mix deps.get\n"
assert setup in s
named = "      - name: Install dependencies\n        run: |\n          mix deps.get\n          test -f newly-required-ci-asset\n"
open(p, "w").write(s.replace(setup, named, 1))
PY
! ci_roster "$gate" "$scratch/roster/named" 2>"$scratch/roster/named.err" ||
  fail 'a named setup step that gained a check passed as setup'
has_line "^test.yml static: 'Install dependencies' is neither run by the gate nor on its list \(it runs 'test -f newly-required-ci-asset', no setup command\)" \
  "$scratch/roster/named.err" || fail "a named setup step with a check failed without its reason: $(cat "$scratch/roster/named.err")"
for spec in 'or:failure() && true || success()' 'success:success()' 'always:failure() && always()' \
  'not:${{ !failure() }}'; do
  name=${spec%%:*} cond=${spec#*:}
  mkdir -p "$scratch/roster/if-$name"
  cp "$root"/.github/workflows/*.yml "$scratch/roster/if-$name/"
  python3 -I - "$scratch/roster/if-$name/test.yml" "$cond" <<'PY'
import sys
p, cond = sys.argv[1], sys.argv[2]; s = open(p).read()
anchor = "      - name: Compile with warnings as errors\n"
assert anchor in s
step = "      - name: A conditioned check\n        if: " + cond + "\n        run: test -f newly-required-ci-asset\n"
open(p, "w").write(s.replace(anchor, step + anchor, 1))
PY
  ! ci_roster "$gate" "$scratch/roster/if-$name" 2>"$scratch/roster/if-$name.err" ||
    fail "a check under if: $cond passed as a report"
  has_line "^test.yml static: 'A conditioned check' is neither run by the gate nor on its list" "$scratch/roster/if-$name.err" ||
    fail "a check under if: $cond failed without its reason: $(cat "$scratch/roster/if-$name.err")"
done
grep -vxF '#   test.yml browser' "$gate" > "$scratch/roster/dropped.sh"
! ci_roster "$scratch/roster/dropped.sh" "$root/.github/workflows" 2>"$scratch/roster/dropped.err" ||
  fail 'a CI job taken off the list passed'
has_line "^test.yml browser: 'The frame-facts experiment' is neither" "$scratch/roster/dropped.err" ||
  fail "a job taken off the list failed without its reason: $(cat "$scratch/roster/dropped.err")"
sed 's/^#   test.yml config-seam$/&\n#   test.yml static: A check CI dropped/' "$gate" > "$scratch/roster/stale.sh"
! ci_roster "$scratch/roster/stale.sh" "$root/.github/workflows" 2>"$scratch/roster/stale.err" || fail 'a stale list entry passed'
has_line '^the list names test.yml static: A check CI dropped, which no pull request runs' "$scratch/roster/stale.err" ||
  fail "a stale list entry failed without its reason: $(cat "$scratch/roster/stale.err")"
echo 'ok: what the gate leaves out'

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

# --- cargo-component missing -------------------------------------------------------
# CARGO_HOME names an empty directory and no directory on PATH holds the
# tool: refused with 69, naming the tool and where it looked, before the
# log directory is made or any leg starts.
mkdir -p "$scratch/empty-cargo"
nocargo_path=
IFS=: read -r -a path_dirs <<<"$scratch/bin:$PATH"
for d in "${path_dirs[@]}"; do
  [ -x "$d/cargo-component" ] || nocargo_path="${nocargo_path:+$nocargo_path:}$d"
done
run_gate nocargo CARGO_HOME="$scratch/empty-cargo" PATH="$nocargo_path" -- "$gate" -l "$scratch/nocargo.log"
[ "$gate_rc" = 69 ] || fail "a gate without cargo-component exited $gate_rc: $(cat "$scratch/nocargo.err")"
framed nocargo "$gate_pid" 69
has_line "cargo-component is neither in $scratch/empty-cargo/bin nor on PATH" "$scratch/nocargo.err" ||
  fail "a gate without cargo-component gave no reason naming where it looked: $(cat "$scratch/nocargo.err")"
no_mix_ran nocargo || fail 'a gate without cargo-component went on to the legs'
[ ! -e "$scratch/nocargo.log" ] || fail 'a gate without cargo-component made its log directory'
# The same PATH with the tool in CARGO_HOME's bin passes the check: the
# gate goes on to its log directory check, which refuses a file.
mkdir -p "$scratch/stub-cargo/bin"
printf '#!/bin/sh\nexit 0\n' > "$scratch/stub-cargo/bin/cargo-component"
chmod +x "$scratch/stub-cargo/bin/cargo-component"
run_gate cargo-home CARGO_HOME="$scratch/stub-cargo" PATH="$nocargo_path" -- "$gate" -l "$scratch/a-file"
[ "$gate_rc" = 64 ] || fail "a gate finding cargo-component in CARGO_HOME exited $gate_rc: $(cat "$scratch/cargo-home.err")"
no_line 'cargo-component' "$scratch/cargo-home.err" || fail "a gate refused cargo-component in CARGO_HOME's bin: $(cat "$scratch/cargo-home.err")"
echo 'ok: cargo-component missing'

# --- a leg run alone ----------------------------------------------------------------
# start_leg NAME LEG [VAR=value...]: the leg as the gate starts it, with a
# fresh log directory and the gate's options in its environment.
start_leg() {
  local name=$1 leg=$2
  shift 2
  mkdir -p "$scratch/$name.log"
  start_gate "$name" GATE_LEG_LOGDIR="$scratch/$name.log" GATE_LEG_PARTS=2 GATE_LEG_CLOSE=false "$@" -- "$gate" --leg "$leg"
}
# --- the islands' copy lists ----------------------------------------------------
# Each island's list is read from its test.yml job: the application, the
# lock, its apps, deps and the WIT tree at least. A planted copy reaches
# the list; a line the gate does not mirror, a copy to another directory
# and a missing job each fail it with the reason.
island_list() { (cd "$1" && . "$gate" && island_spec "$2"); }
for isl in prima arca sanctum locus; do
  spec=$(island_list "$root" "$isl") || fail "the $isl island's list could not be read from test.yml"
  [ "${spec%% *}" = "$isl" ] || fail "the $isl island's list names another application: $spec"
  for p in mix.lock "apps/$isl" deps wit; do
    case " $spec " in *" $p "*) ;; *) fail "the $isl island's list lacks $p: $spec" ;; esac
  done
done
plant_islands() {
  mkdir -p "$scratch/islands-$1/.github/workflows"
  python3 -I - "$root/.github/workflows/test.yml" "$scratch/islands-$1/.github/workflows/test.yml" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, old
open(dst, "w").write(s.replace(old, new))
PY
}
arca_copy='          cp config/database_choice.exs "$island/config/"
          cd "$island/apps/arca"'
plant_islands added "$arca_copy" '          cp config/database_choice.exs "$island/config/"
          cp -R tests/fixtures "$island/tests/"
          cd "$island/apps/arca"'
[ "$(island_list "$scratch/islands-added" arca)" = "$(island_list "$root" arca) tests/fixtures" ] ||
  fail "a copy planted in the arca job did not reach the gate's list: $(island_list "$scratch/islands-added" arca)"
plant_islands unknown "$arca_copy
          mix compile --warnings-as-errors
          mix test" "$arca_copy
          mix compile --warnings-as-errors
          mix test --include slow"
! island_list "$scratch/islands-unknown" arca 2>"$scratch/islands-unknown.err" || fail 'an island step the gate does not mirror was read'
has_line 'runs a line the gate does not mirror: mix test --include slow' "$scratch/islands-unknown.err" ||
  fail "an island step the gate does not mirror failed without its reason: $(cat "$scratch/islands-unknown.err")"
plant_islands elsewhere "$arca_copy" '          cp config/database_choice.exs "$island/"
          cd "$island/apps/arca"'
! island_list "$scratch/islands-elsewhere" arca 2>"$scratch/islands-elsewhere.err" || fail 'a copy to another directory was read'
has_line 'copies config/database_choice.exs to \$island/, which the gate does not mirror' "$scratch/islands-elsewhere.err" ||
  fail "a copy to another directory failed without its reason: $(cat "$scratch/islands-elsewhere.err")"
plant_islands missing '  arca-independence:' '  arca-elsewhere:'
! island_list "$scratch/islands-missing" arca 2>"$scratch/islands-missing.err" || fail 'a missing island job was read'
has_line 'test.yml has no arca-independence job' "$scratch/islands-missing.err" ||
  fail "a missing island job failed without its reason: $(cat "$scratch/islands-missing.err")"
echo 'ok: the islands copy what test.yml copies'

# A selection git cannot read fails the postgres leg after its compiles,
# with its marker, and no test runs.
start_leg pgread postgres GIT_DIR=/nonexistent
gate_status "$gate_pid"
[ "$gate_rc" = 1 ] || fail "a postgres leg whose selection could not be read exited $gate_rc"
[ "$(tr '\n' ' ' < "$scratch/pgread.log/postgres.summary")" = 'compile_pg_test=0 compile_pg_dev=0 pg_selection_read=1 ' ] ||
  fail "an unreadable selection was not recorded: $(tr '\n' ' ' < "$scratch/pgread.log/postgres.summary")"
[ -e "$scratch/pgread.log/postgres.done" ] || fail 'the postgres leg left no marker after an unreadable selection'
[ "$(awk -F'|' '{ print $1 ":" $6 }' "$scratch/pgread.trace/mix.calls" | tr '\n' ' ')" = 'test:compile --force --warnings-as-errors dev:compile --force --warnings-as-errors ' ] ||
  fail "the postgres leg ran more than its compiles: $(tr '\n' ' ' < "$scratch/pgread.trace/mix.calls")"
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
  apps/cyfr/test/aqua/loop/flush_test.exs \
  apps/cyfr/test/integration/runtime/attached_fetch_test.exs \
  apps/cyfr/test/integration/runtime/model_contract_test.exs \
  apps/cyfr/test/integration/runtime/secret_audit_test.exs \
  apps/cyfr/test/integration/runtime/seed_model_catalysts_test.exs; do
  [ -f "$root/$f" ] || fail "a listed adapter-branching file is gone: $f"
  grep -qxF "$f" "$scratch/selection.txt" || fail "the selection misses $f"
done
# The last four name Cyfr.Test.ChatFixture, whose adapter branch is in
# the support module: three of them through a multi-alias alone.
grep -qE "$(. "$gate" && echo "$PG_PATTERN")" "$root/apps/cyfr/test/support/chat_fixture.ex" ||
  fail 'Cyfr.Test.ChatFixture no longer branches on the adapter: name another support case'
# Each exempt support module still matches the pattern, in a tracked
# support file that defines it: an exemption with nothing to exempt is stale.
for m in $(. "$gate" && echo "$PG_SUPPORT_EXEMPT"); do
  f=$(cd "$root" && git grep -l -E "^defmodule ${m//./\\.} do\$" -- ':(glob)apps/*/test/support/**') || f=
  [ -n "$f" ] || fail "the exempt support module $m is defined in no tracked support file"
  grep -qE "$(. "$gate" && echo "$PG_PATTERN")" "$root/$f" || fail "the exempt support module $m no longer matches the pattern"
done
no_line '^apps/cyfr/test/cyfr/cell_test.exs$' "$scratch/selection.txt" || fail 'the selection holds cell_test.exs, which does not branch'
# Every test file carrying :requires_cargo_component, as CI's PostgreSQL
# job runs them.
cargo_files=$(cd "$root" && git grep -l -E ':requires_cargo_component\b' -- ':(glob)apps/*/test/**/*_test.exs') ||
  fail 'no test file carries :requires_cargo_component: the selection check has nothing to hold'
for f in $cargo_files; do grep -qxF "$f" "$scratch/selection.txt" || fail "the selection misses the cargo-tagged $f"; done
for f in apps/cyfr/test/integration/locus/compile_lock_test.exs apps/locus/test/locus/builder_test.exs; do
  grep -qxF "$f" "$scratch/selection.txt" || fail "the selection misses $f"
done
# Planted in a repository of their own: git grep reads tracked files only.
plant="$scratch/plant"
mkdir -p "$plant/apps/x/test/support" "$plant/apps/x/lib" "$plant/apps/arca/test"
git -C "$plant" init -q
printf 'test "a" do\n  if Arca.Test.Adapter.postgres?() do :pg else :lite end\nend\n' > "$plant/apps/x/test/branch_test.exs"
printf '@tag :sqlite\ntest "b", do: :ok\n' > "$plant/apps/x/test/tagged_test.exs"
printf 'test "c", do: assert 1 == 1\n' > "$plant/apps/x/test/plain_test.exs"
printf 'test "d", do: my_postgres?()\n' > "$plant/apps/x/test/lookalike_test.exs"
printf '@tag :postgres\n' > "$plant/apps/arca/test/stored_test.exs"
printf '@moduletag :requires_cargo_component\n' > "$plant/apps/x/test/cargo_test.exs"
printf '@tag :postgres\n' > "$plant/apps/x/test/support/case.ex"
printf '@tag :postgres\n' > "$plant/apps/x/lib/thing_test.exs"
# A support module that branches on the adapter, named in full, in a
# multi-alias across lines, and by a longer name or a longer leaf that are
# not it; and one exempt support module, whose users are not selected.
printf 'defmodule X.Test.Branching do\n  def f, do: Arca.Test.Adapter.postgres?()\nend\n' > "$plant/apps/x/test/support/branching.ex"
printf 'defmodule Arca.Test.Sandbox do\n  def s, do: Arca.Repo.adapter()\nend\n' > "$plant/apps/x/test/support/sandbox.ex"
printf 'test "e", do: X.Test.Branching.f()\n' > "$plant/apps/x/test/full_test.exs"
printf 'alias X.Test.{\n  Other,\n  Branching\n}\ntest "f", do: Branching.f()\n' > "$plant/apps/x/test/alias_test.exs"
printf 'test "g", do: X.Test.BranchingMore.f()\n' > "$plant/apps/x/test/longer_test.exs"
printf 'alias X.Test.{Other, Branchings}\ntest "h", do: :ok\n' > "$plant/apps/x/test/leaf_test.exs"
printf 'test "i", do: Arca.Test.Sandbox.s()\n' > "$plant/apps/x/test/sandboxed_test.exs"
printf 'defmodule X.Test.Wrapper do\n  def f, do: X.Test.Branching.f()\nend\n' > "$plant/apps/x/test/support/wrapper.ex"
printf 'alias X.Test\ntest "parent", do: Test.Branching.f()\n' > "$plant/apps/x/test/parent_namespace_test.exs"
printf 'alias X.Test.Wrapper\ntest "chain", do: Wrapper.f()\n' > "$plant/apps/x/test/support_chain_test.exs"
# The selection's two stated limits, planted and expected unselected: a
# wrapper of a wrapper, and a renamed alias of a one-segment root. The
# close gate's whole suite covers them.
printf 'defmodule X.Test.Outer do\n  def f, do: X.Test.Wrapper.f()\nend\n' > "$plant/apps/x/test/support/outer.ex"
printf 'alias X.Test.Outer\ntest "outer", do: Outer.f()\n' > "$plant/apps/x/test/outer_chain_test.exs"
printf 'alias X, as: T\ntest "root", do: T.Test.Branching.f()\n' > "$plant/apps/x/test/renamed_root_test.exs"
git -C "$plant" add apps
printf '@tag :postgres\n' > "$plant/apps/x/test/untracked_test.exs"
selection "$plant" > "$scratch/plant.txt" || fail 'the selection failed on the planted repository'
[ "$(tr '\n' ' ' < "$scratch/plant.txt")" = 'apps/arca/test apps/cyfr/test/arca apps/x/test/alias_test.exs apps/x/test/branch_test.exs apps/x/test/cargo_test.exs apps/x/test/full_test.exs apps/x/test/parent_namespace_test.exs apps/x/test/support_chain_test.exs apps/x/test/tagged_test.exs ' ] ||
  fail "the planted selection is wrong: $(tr '\n' ' ' < "$scratch/plant.txt")"
# A matcher that cannot run fails the selection rather than answering it
# incomplete: the planted repository's selection succeeds with Perl and is
# refused with a Perl that exits 2.
(cd "$plant" && . "$gate" && perl() { return 2; } && ! pg_selection > "$scratch/plant-matcher-error.txt") ||
  fail "the selection succeeded with a matcher that exits 2: $(tr '\n' ' ' < "$scratch/plant-matcher-error.txt")"
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
# Each island held what its test.yml job gives it, and nothing else.
for isl in prima arca sanctum; do
  read -r -a paths <<<"$(island_list "$root" "$isl")"
  want=$(for p in "${paths[@]:1}"; do echo "${p%%/*}"; case $p in */*) echo "$p" ;; esac; done | LC_ALL=C sort -u)
  [ "$(cat "$scratch/pass.trace/island.$isl.tree")" = "$want" ] ||
    fail "the $isl island held $(tr '\n' ' ' < "$scratch/pass.trace/island.$isl.tree"), not test.yml's $(echo $want)"
done
echo 'ok: a whole gate that passes, every suite with a result'

# --- a whole gate: a stalled island, build paths, the pg leg, the framing --------
# Started by a relative path from another directory; the caller's build
# path is the PostgreSQL one. The arca island's tests stall with a
# grandchild and reach their deadline; the sanctum island's compile takes
# ten seconds and its tests hold, so the gate still runs when arca is
# stopped. The twenty-second step deadline reaches the islands leg alone,
# through BASH_ENV as above: the static leg runs the real fixture recipes
# and npm checks, which a loaded runner can keep past twenty seconds.
mkdir -p "$scratch/tmp-a"
printf 'case "${1:-}:${2:-}" in --leg:islands) export GATE_STEP_DEADLINE=20 ;; esac\n' > "$scratch/a.bash_env"
cd "$root/scripts"
start_gate a TMPDIR="$scratch/tmp-a" MIX_BUILD_PATH=_build/test_pg BASH_ENV="$scratch/a.bash_env" \
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
for s in compile_sqlite_test compile_sqlite_dev js_suite eslint wasm_tools test_wasm sdk_bundle toolkit_bundle canary_checks imagesuite_checks worker_auth_check backends_check dialyzer boundary_plants sqlite_suite; do
  has_line "^$s=0$" "$scratch/a.log/static.summary" || fail "the static step $s did not pass: $(tr '\n' ' ' < "$scratch/a.log/static.summary")"
done
has_line '^compile_pg_dev=0$' "$scratch/a.log/postgres.summary" || fail "the PostgreSQL dev compile did not pass: $(tr '\n' ' ' < "$scratch/a.log/postgres.summary")"
has_line '^pg_tests=0$' "$scratch/a.log/postgres.summary" || fail "the PostgreSQL tests did not pass: $(tr '\n' ' ' < "$scratch/a.log/postgres.summary")"
has_line '^fossils=0$' "$scratch/a.log/vocab.summary" || fail 'the vocabulary leg did not pass'
has_line '^==> islands +FAILED ' "$scratch/a.out" || fail 'the islands leg was not reported failed'
has_line '^==> static +ok .*canary_checks=0 imagesuite_checks=0 worker_auth_check=0 backends_check=0 ' "$scratch/a.out" || fail 'the static leg and its Python checks were not reported passed'
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
build_path "^dev\|postgres\|[^|]*\|-\|$root\|compile --force" _build/dev_pg
build_path "^-\|-\|[^|]*\|-\|$root\|(format|credo|ops.gen.cli|cyfr.gen.configuration_guide|dialyzer)" -
build_path '^test\|postgres\|' _build/test_pg
build_path '^[^|]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*/island_[^|]*\|' -
# Every island phase runs under MIX_ENV=test, as CI's island jobs do, so
# its compile builds the island's test/support with warnings as errors.
for isl in prima arca sanctum; do
  grep -qE "^test\|sqlite\|[^|]*\|-\|[^|]*/island_${isl}\.[^|]*/apps/${isl}\|compile --warnings-as-errors\$" "$calls" ||
    fail "the $isl island did not compile under MIX_ENV=test: $(grep "/island_${isl}" "$calls" | tr '\n' ' ')"
done
[ -z "$(awk -F'|' '$5 ~ /\/island_/ && $1 != "test"' "$calls")" ] ||
  fail "an island phase ran outside MIX_ENV=test: $(awk -F'|' '$5 ~ /\/island_/ && $1 != "test"' "$calls" | tr '\n' ' ')"
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

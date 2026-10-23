#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/fetch-precompiled-nifs.sh against rustler_precompiled itself,
# each run on a cache and a build of the test's own:
#   - into an empty cache it fetches this machine's wasmex NIF, and a
#     compile of wasmex, every rustler_precompiled download sent to a
#     closed port, finds the file there and extracts it; the module, file
#     name, URL and cache path the script prints are the ones that compile
#     recorded (its metadata file and RustlerPrecompiled.current_target_nifs/1),
#     so an upgrade of wasmex or rustler_precompiled that names another
#     file or URL fails here;
#   - a second run, curl's downloads sent to the closed port too, keeps the
#     cached file;
#   - a call of `use RustlerPrecompiled` the script does not read is
#     refused;
#   - a download that does not match the dep's checksum file is refused,
#     and nothing is cached;
#   - a cached file that does not match is replaced by one that does.
# Two controls show the closed port closes: the same compile with an empty
# cache fails at it, and so does the script with an empty cache. First,
# every tracked script, workflow and Dockerfile that runs `mix deps.get`
# runs the fetch as its next command.
# It downloads from GitHub, and needs the checkout's deps (mix deps.get).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
fetch="$root/scripts/fetch-precompiled-nifs.sh"
scratch=$(mktemp -d /tmp/cyfr-fetch-nifs-test.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"
# The caller's Mix and cache selections are not the test's.
unset MIX_BUILD_PATH MIX_DEPS_PATH MIX_XDG RUSTLER_PRECOMPILED_FORCE_BUILD_ALL WASMEX_BUILD
export MIX_ENV=test
# The script's scratch directories go here (Mix's build lock too), and
# each is gone after its run.
export TMPDIR="$scratch/tmp"
mkdir "$TMPDIR"
closed=http://127.0.0.1:9
offline() { env HTTPS_PROXY="$closed" https_proxy="$closed" "$@"; }

# Compiles wasmex in build $1 against cache $2: rustler_precompiled's
# downloads (:httpc, which takes HTTPS_PROXY) reach only the closed port.
compile_wasmex() {
  offline MIX_BUILD_PATH="$1" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$2" \
    mix deps.compile rustler_precompiled rustler wasmex
}

# Each `mix deps.get` a tracked file runs, outside comments, the docs and
# the gate's own fixtures, is followed by the fetch: on its line after
# `&&`, or alone on the next line.
git grep -n -e 'mix deps\.get' -- ':!*.md' ':!deps' ':!tests/commit-gate-test.sh' \
  ':!scripts/lib/workflow_plan.py' ':!tests/fetch-precompiled-nifs-test.sh' > "$scratch/deps-get.txt" || true
python3 -I - "$scratch/deps-get.txt" <<'PY'
import re, sys
bad, seen = [], 0
for hit in open(sys.argv[1]).read().splitlines():
    path, line, text = hit.split(":", 2)
    if text.lstrip().startswith("#"):
        continue
    seen += 1
    nxt = open(path).read().split("\n")[int(line)]
    if not (re.search(r"mix deps\.get[^&;|]*&& scripts/fetch-precompiled-nifs\.sh\b", text)
            or re.fullmatch(r"\s*scripts/fetch-precompiled-nifs\.sh( &&)?", nxt)):
        bad.append(f"{path}:{line}: {text.strip()}")
if not seen:
    sys.exit("FAIL: no tracked file runs mix deps.get, so the scan checked nothing")
if bad:
    sys.exit("FAIL: mix deps.get without scripts/fetch-precompiled-nifs.sh after it:\n  " + "\n  ".join(bad))
PY

cache="$scratch/cache"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" > "$scratch/first.out" ||
  fail "the fetch into an empty cache failed"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" --print > "$scratch/print.out" ||
  fail "--print failed"
[ "$(wc -l < "$scratch/print.out")" -eq 1 ] ||
  fail "the script names other NIFs than wasmex's, which this test holds to rustler_precompiled: $(cat "$scratch/print.out")"
IFS=$'\t' read -r module file url path < "$scratch/print.out"
[ "$path" = "$cache/$file" ] || fail "the cache path $path is not in the cache rustler_precompiled was given"
[ -f "$path" ] || fail "the fetch left no $path"
grep -qxF "$file fetched from $url to $path" "$scratch/first.out" ||
  fail "the fetch did not report the download: $(cat "$scratch/first.out")"
[ -z "$(ls -A "$cache" | grep -vxF "$file")" ] || fail "the fetch left more than the NIF in the cache: $(ls -A "$cache")"

compile_wasmex "$scratch/build" "$cache" > "$scratch/compile.log" 2>&1 ||
  fail "wasmex did not compile from the fetched cache: $(tail -n 20 "$scratch/compile.log")"
[ -f "$scratch/build/lib/wasmex/priv/native/${file%.tar.gz}" ] ||
  fail "the compile extracted no ${file%.tar.gz}"
# What rustler_precompiled recorded for this target at the compile.
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" elixir -pa "$scratch/build/lib/rustler_precompiled/ebin" -e '
  Logger.configure(level: :warning)
  module = Wasmex.Native
  {meta, _} = Code.eval_file(Path.join(System.fetch_env!("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"), "metadata-#{module}.exs"))
  {url, _} = module |> RustlerPrecompiled.current_target_nifs() |> List.keyfind(meta.file_name, 0) |> elem(1)
  IO.puts(Enum.join([inspect(module), meta.file_name, url, meta.cached_tar_gz], "\t"))
' > "$scratch/recorded.out" || fail "the compile's record could not be read"
diff "$scratch/recorded.out" "$scratch/print.out" > "$scratch/record.diff" ||
  fail "the script's module, file name, URL and cache path are not what rustler_precompiled recorded: $(cat "$scratch/record.diff")"

# Control: with nothing cached, the same compile fails at the closed port.
! compile_wasmex "$scratch/build-empty" "$scratch/cache-empty" > "$scratch/control.log" 2>&1 ||
  fail "wasmex compiled with nothing cached and its download closed: the compile above proves nothing"
grep -q 'econnrefused' "$scratch/control.log" ||
  fail "the control compile failed, but not at the closed port: $(tail -n 20 "$scratch/control.log")"

before=$(sha256sum "$path")
offline RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" > "$scratch/second.out" ||
  fail "a second run with the file cached failed"
grep -qxF "$file is cached at $path" "$scratch/second.out" ||
  fail "a second run did not keep the cached file: $(cat "$scratch/second.out")"
[ "$(sha256sum "$path")" = "$before" ] || fail "a second run changed the cached file"
# Control: with nothing cached, the script fails at the closed port.
! offline RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$scratch/cache-offline" "$fetch" > /dev/null 2> "$scratch/offline.err" ||
  fail "the script fetched with curl sent to the closed port: the second run above proves nothing"
grep -q 'curl could not fetch' "$scratch/offline.err" ||
  fail "the offline control failed, but not at curl: $(cat "$scratch/offline.err")"

# A checksum file that names another sha256 for this target: the download
# is refused and nothing is cached.
mkdir "$scratch/deps"
cp -R deps/rustler_precompiled deps/wasmex "$scratch/deps/"
sums="$scratch/deps/wasmex/checksum-Elixir.$module.exs"
python3 -I - "$sums" "$file" <<'PY'
import re, sys
p, name = sys.argv[1], sys.argv[2]
s = open(p).read()
t, n = re.subn(r'("' + re.escape(name) + r'" => "sha256:)[0-9a-f]{64}"', r'\g<1>' + "0" * 64 + '"', s)
assert n == 1, f"{name} is not once in {p}"
open(p, "w").write(t)
PY
status=0
MIX_DEPS_PATH="$scratch/deps" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$scratch/cache-bad" "$fetch" \
  > /dev/null 2> "$scratch/bad.err" || status=$?
[ "$status" -eq 1 ] || fail "a download that does not match its checksum exited $status, not 1"
grep -qF "$url does not match wasmex's checksum file" "$scratch/bad.err" ||
  fail "a checksum mismatch was refused without its reason: $(cat "$scratch/bad.err")"
[ -z "$(ls -A "$scratch/cache-bad" 2>/dev/null)" ] ||
  fail "a refused download left $(ls -A "$scratch/cache-bad") in the cache"

# A call the script does not read, here inside a condition, is refused
# rather than skipped.
mkdir "$scratch/deps-nested"
cp -R deps/rustler_precompiled deps/wasmex "$scratch/deps-nested/"
native="$scratch/deps-nested/wasmex/lib/wasmex/native.ex"
python3 -I - "$native" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
t, n = re.subn(r"(?ms)^  use RustlerPrecompiled,.*?\n\n", lambda m: "  if true do\n" + m.group(0)[:-1] + "  end\n\n", s, count=1)
assert n == 1, f"no use RustlerPrecompiled call in {p}"
open(p, "w").write(t)
PY
status=0
MIX_DEPS_PATH="$scratch/deps-nested" "$fetch" --print > /dev/null 2> "$scratch/nested.err" || status=$?
[ "$status" -eq 1 ] || fail "a nested use RustlerPrecompiled exited $status, not 1"
grep -qF "$native calls \`use RustlerPrecompiled\` outside a top-level module's own statements" "$scratch/nested.err" ||
  fail "a nested use RustlerPrecompiled was refused without its reason: $(cat "$scratch/nested.err")"

# A cached file that does not match is fetched again, and the match kept.
echo 'not a NIF' > "$path"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" > "$scratch/repair.out" 2> "$scratch/repair.err" ||
  fail "a cached file that does not match was not replaced: $(cat "$scratch/repair.err")"
grep -qxF "$path does not match wasmex's checksum file; fetching it again" "$scratch/repair.err" ||
  fail "the replacement of a cached file that does not match was not reported: $(cat "$scratch/repair.err")"
[ "$(sha256sum "$path")" = "$before" ] || fail "the replaced file is not the one that matches"
[ -z "$(ls -A "$cache" | grep -vxF -e "$file" -e "metadata-Elixir.$module.exs")" ] ||
  fail "the replacement left more in the cache: $(ls -A "$cache")"

[ -z "$(ls -A "$TMPDIR" | grep '^fetch-precompiled-nifs\.')" ] || fail "a run left its scratch behind: $(ls -A "$TMPDIR")"

echo "fetch-precompiled-nifs: $file fetched, verified and found by the compile as rustler_precompiled names it; a mismatch refused"

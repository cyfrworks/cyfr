#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/fetch-precompiled-nifs.sh against rustler_precompiled and tailwind
# themselves,
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
#   - a relative RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH lays the file under
#     the dep's directory, where the dep's compile finds it;
#   - a cached file that does not match is replaced by one that does;
#   - the tailwind pins hold the configured version and this machine's
#     target, the CLI laid down is the pinned one, executable, where
#     `mix tailwind prism` runs it from, its download closed; a second run
#     keeps it; a pin that does not match, and a version without one, are
#     refused with nothing laid down.
# Three controls show the closed port closes: the same compile with an
# empty cache fails at it, so does the script with an empty cache, and so
# does `mix tailwind prism` with nothing laid down. First,
# every invocation of `mix deps.get` in a tracked file runs the fetch as
# its next command.
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

# Each `mix deps.get` a tracked file invokes is followed by the fetch: on
# its line after `&&`, or alone on the next line. An invocation is the
# words at a command position (a line's start, or after RUN, run:, &&, ||,
# ; or |) outside a quoted string and a comment, read a line at a time; the
# same words in a message, a comment or the docs' prose are not one. The
# reading is held first to cases that must and must not match.
python3 -I - "$root" <<'PY'
import re, subprocess, sys

FETCH = "scripts/fetch-precompiled-nifs.sh"
WORDS = "mix deps.get"

def outside(text):
    """Each offset of text that is outside quotes and comments, as a set."""
    out, quote, i = set(), None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
        elif c == "#":
            break
        else:
            out.add(i)
        i += 1
    return out

def invocations(lines):
    """(line number, followed by the fetch) for each invocation in lines."""
    found = []
    for n, text in enumerate(lines):
        free = outside(text)
        for m in re.finditer(re.escape(WORDS) + r"(?![\w.-])", text):
            if m.start() not in free:
                continue
            before = text[:m.start()].rstrip()
            if not (before == "" or before.endswith(("&&", ";", "|", "run:")) or re.search(r"(?:^|\s)RUN$", before)):
                continue
            rest = text[m.end():]
            nxt = lines[n + 1] if n + 1 < len(lines) else ""
            followed = bool(re.match(r"[^&;|]*&& " + re.escape(FETCH) + r"(?![\w.-])", rest)) or (
                re.fullmatch(r"[^&;|]*(?:&&)?\s*\\?", rest) is not None
                and re.fullmatch(r"\s*" + re.escape(FETCH) + r"(?: &&| \\)?\s*", nxt) is not None)
            found.append((n + 1, followed))
    return found

# The fetch's own refusals, which name the command in a string, and the
# other words that are no invocation.
NOT = [
    '    refuse.("#{rustler_precompiled} holds no rustler_precompiled: run mix deps.get first")',
    '    refuse.("no locked dep in #{deps} calls `use RustlerPrecompiled`: run mix deps.get first, or drop this script once no dep needs it")',
    "      # The fetch every job runs after mix deps.get names the file and URL",
    "- After `mix deps.get` in a fresh checkout, and after a change to",
    'SETUP_RUNS = {"mix deps.get\\nscripts/fetch-precompiled-nifs.sh"}',
    "mix deps.getter",
    "echo then mix deps.get",
    # At a command position, and in a string or a comment all the same.
    """has_line "^test.yml static: 'run: mix deps.get; test -f x' is neither run by the gate" \\""",
    "step = '      - run: mix deps.get\\n'",
    "      # run: mix deps.get",
    "true # && mix deps.get",
]
IS = [
    "mix deps.get",
    "          mix deps.get",
    "      - run: mix deps.get",
    "RUN mix deps.get --only prod && mix deps.compile",
    'cd "$root" && mix deps.get',
    "true; mix deps.get",
    "yes | mix deps.get",
]
FOLLOWED = [
    (["RUN mix deps.get --only prod && scripts/fetch-precompiled-nifs.sh && mix deps.compile"], True),
    (["          mix deps.get", "          scripts/fetch-precompiled-nifs.sh"], True),
    (["      mix deps.get --only prod &&", "        scripts/fetch-precompiled-nifs.sh &&"], True),
    (["RUN mix deps.get --only prod && mix deps.compile"], False),
    (["          mix deps.get", "          mix compile"], False),
    (["mix deps.get && mix compile", "scripts/fetch-precompiled-nifs.sh"], False),
]
wrong = [f"read as an invocation: {t}" for t in NOT if invocations([t])]
wrong += [f"not read as an invocation: {t}" for t in IS if len(invocations([t])) != 1]
wrong += [f"read as {'not ' if want else ''}followed by the fetch: {' / '.join(ls)}"
          for ls, want in FOLLOWED if invocations(ls) != [(1, want)]]
if wrong:
    sys.exit("FAIL: the invocation reading is wrong:\n  " + "\n  ".join(wrong))

root = sys.argv[1]
paths = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True).stdout.split(b"\0")
bad, seen = [], 0
for path in (p.decode() for p in paths if p):
    try:
        text = open(f"{root}/{path}", encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    if WORDS not in text:
        continue
    lines = text.split("\n")
    for n, followed in invocations(lines):
        seen += 1
        if not followed:
            bad.append(f"{path}:{n}: {lines[n - 1].strip()}")
if not seen:
    sys.exit("FAIL: no tracked file invokes mix deps.get, so the scan checked nothing")
if bad:
    sys.exit(f"FAIL: mix deps.get without {FETCH} after it:\n  " + "\n  ".join(bad))
print(f"every one of {seen} invocations of mix deps.get is followed by the fetch")
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
grep -qxF "$file is in place at $path" "$scratch/second.out" ||
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

# A relative RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH, given from another
# directory: the fetch lays the file under the dep's own directory, where
# the dep's compile resolves the override, and the compile, its download
# closed, finds it there. The deps are a copy of the test's, so nothing is
# written into the checkout's.
mkdir "$scratch/deps-rel" "$scratch/elsewhere"
cp -R deps/rustler_precompiled deps/rustler deps/jason deps/wasmex "$scratch/deps-rel/"
rel=relative-cache
(cd "$scratch/elsewhere" && MIX_DEPS_PATH="$scratch/deps-rel" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$rel" "$fetch" --print) \
  > "$scratch/rel-print.out" || fail "--print with a relative cache failed"
[ "$(cut -f4 "$scratch/rel-print.out")" = "$scratch/deps-rel/wasmex/$rel/$file" ] ||
  fail "a relative cache does not resolve under the dep's directory: $(cat "$scratch/rel-print.out")"
(cd "$scratch/elsewhere" && MIX_DEPS_PATH="$scratch/deps-rel" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$rel" "$fetch") \
  > /dev/null || fail "the fetch into a relative cache failed"
[ -f "$scratch/deps-rel/wasmex/$rel/$file" ] || fail "the fetch into a relative cache left no file under the dep"
[ ! -e "$scratch/elsewhere/$rel" ] || fail "the fetch into a relative cache wrote under the caller's directory"
MIX_DEPS_PATH="$scratch/deps-rel" compile_wasmex "$scratch/build-rel" "$rel" > "$scratch/rel-compile.log" 2>&1 ||
  fail "wasmex did not compile from the relative cache the fetch filled: $(tail -n 20 "$scratch/rel-compile.log")"

# A cached file that does not match is fetched again, and the match kept.
echo 'not a NIF' > "$path"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" > "$scratch/repair.out" 2> "$scratch/repair.err" ||
  fail "a cached file that does not match was not replaced: $(cat "$scratch/repair.err")"
grep -qxF "$path does not match wasmex's checksum file; fetching it again" "$scratch/repair.err" ||
  fail "the replacement of a cached file that does not match was not reported: $(cat "$scratch/repair.err")"
[ "$(sha256sum "$path")" = "$before" ] || fail "the replaced file is not the one that matches"
[ -z "$(ls -A "$cache" | grep -vxF -e "$file" -e "metadata-Elixir.$module.exs")" ] ||
  fail "the replacement left more in the cache: $(ls -A "$cache")"

# --- tailwind ------------------------------------------------------------------
# The pins hold the configured version and this machine's target; the CLI
# laid down where `mix tailwind` looks, in a build of the test's own, is the
# one pinned and executable; the real `mix tailwind prism`, its download
# closed, runs from it and writes its CSS (to the test's directory). Control:
# the same run with nothing laid down fails at the closed port.
tw="$scratch/tw/test"
MIX_BUILD_PATH="$tw" "$fetch" --tailwind --print > "$scratch/tw-print.out" 2> "$scratch/tw-print.err" ||
  fail "the pins do not hold the configured tailwind version and target: $(cat "$scratch/tw-print.err")"
[ "$(wc -l < "$scratch/tw-print.out")" -eq 1 ] || fail "the configuration runs more than one tailwind: $(cat "$scratch/tw-print.out")"
IFS=$'\t' read -r _ tw_version tw_target tw_url tw_bin < "$scratch/tw-print.out"
[ "$tw_bin" = "$scratch/tw/tailwind-$tw_target-$tw_version" ] || fail "the tailwind path $tw_bin is not beside the test's build"
MIX_BUILD_PATH="$tw" "$fetch" --tailwind > "$scratch/tw-first.out" || fail "the tailwind fetch failed"
grep -qxF "tailwind-$tw_target-$tw_version fetched from $tw_url to $tw_bin" "$scratch/tw-first.out" ||
  fail "the tailwind fetch did not report the download: $(cat "$scratch/tw-first.out")"
[ -x "$tw_bin" ] || fail "the laid-down tailwind is not executable"
pin=$(awk -v v="$tw_version" -v t="$tw_target" '$1 == v && $2 == t { print $3 }' "$fetch")
[ -n "$pin" ] && [ "$(sha256sum "$tw_bin" | cut -d' ' -f1)" = "$pin" ] || fail "the laid-down tailwind is not the pinned one"
offline MIX_BUILD_PATH="$tw" "$fetch" --tailwind > "$scratch/tw-second.out" || fail "a second tailwind run failed"
grep -qxF "tailwind-$tw_target-$tw_version is in place at $tw_bin" "$scratch/tw-second.out" ||
  fail "a second tailwind run did not keep the binary: $(cat "$scratch/tw-second.out")"
tailwind_prism() {
  MIX_BUILD_PATH="$1" mix deps.compile tailwind > /dev/null 2>&1 || return
  offline MIX_BUILD_PATH="$1" mix do loadpaths --no-deps-check + tailwind prism --output="$2"
}
tailwind_prism "$tw" "$scratch/tw.css" > "$scratch/tw-run.log" 2>&1 ||
  fail "mix tailwind prism did not run from the laid-down CLI: $(tail -n 20 "$scratch/tw-run.log")"
[ -s "$scratch/tw.css" ] || fail "mix tailwind prism wrote no CSS"
! tailwind_prism "$scratch/tw-empty/test" "$scratch/tw-empty.css" > "$scratch/tw-control.log" 2>&1 ||
  fail "mix tailwind prism ran with nothing laid down and its download closed: the run above proves nothing"
grep -q 'failed_connect' "$scratch/tw-control.log" ||
  fail "the tailwind control failed, but not at the closed port: $(tail -n 20 "$scratch/tw-control.log")"

# A pin that does not match, and a version the pins do not hold, each in a
# copy of the script beside the checkout's project: refused, nothing laid
# down.
for case in mismatch unknown; do
  copy="$scratch/root-$case"
  mkdir -p "$copy/scripts"
  for f in mix.exs config deps apps; do ln -s "$root/$f" "$copy/$f"; done
  case "$case" in
    mismatch) sed "s/^$tw_version $tw_target $pin\$/$tw_version $tw_target $(printf '%064d' 0)/" "$fetch" ;;
    unknown) sed "s/^$tw_version /0.0.0 /" "$fetch" ;;
  esac > "$copy/scripts/fetch-precompiled-nifs.sh"
  chmod +x "$copy/scripts/fetch-precompiled-nifs.sh"
  ! cmp -s "$fetch" "$copy/scripts/fetch-precompiled-nifs.sh" || fail "the $case copy of the script changed nothing"
  status=0
  MIX_BUILD_PATH="$scratch/tw-$case/test" "$copy/scripts/fetch-precompiled-nifs.sh" --tailwind \
    > /dev/null 2> "$scratch/tw-$case.err" || status=$?
  [ "$status" -eq 1 ] || fail "the tailwind $case exited $status, not 1"
  [ ! -e "$scratch/tw-$case/tailwind-$tw_target-$tw_version" ] || fail "the tailwind $case laid a binary down"
done
grep -qF "$tw_url does not match the sha256 pinned for tailwind $tw_version on $tw_target" "$scratch/tw-mismatch.err" ||
  fail "a tailwind download that does not match its pin was refused without its reason: $(cat "$scratch/tw-mismatch.err")"
grep -qF "no sha256 is pinned for tailwind $tw_version on $tw_target" "$scratch/tw-unknown.err" ||
  fail "a tailwind version without a pin was refused without its reason: $(cat "$scratch/tw-unknown.err")"

[ -z "$(ls -A "$TMPDIR" | grep '^fetch-precompiled-nifs\.')" ] || fail "a run left its scratch behind: $(ls -A "$TMPDIR")"

echo "fetch-precompiled-nifs: $file and tailwind $tw_version fetched, verified and found where their own downloads look; mismatches refused"

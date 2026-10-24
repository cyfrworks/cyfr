#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/fetch-prebuilt-binaries.sh against the deps' own downloads
# (rustler_precompiled's, elixir_make's and tailwind's), each run on a
# cache and a build of the test's own. First, every tracked invocation of
# `mix deps.get` runs the fetch after it, and every one of
# `mix assets.deploy` and `mix tailwind` the tailwind fetch before it.
# Then:
#   - into an empty cache it fetches this machine's wasmex NIF, and a
#     compile of wasmex, every rustler_precompiled download sent to a
#     closed port, finds the file there and extracts it; the module, file
#     name, URL and cache path the script prints are the ones that compile
#     recorded (its metadata file and RustlerPrecompiled.current_target_nifs/1),
#     so an upgrade of wasmex or rustler_precompiled that names another
#     file or URL fails here;
#   - it fetches exqlite's and lazy_html's archives into elixir_make's
#     cache, and a compile of both, every download closed, tries no
#     download and builds nothing from source;
#   - a second run, curl's downloads sent to the closed port too, keeps the
#     cached file;
#   - a call of `use RustlerPrecompiled` the script does not read is
#     refused;
#   - a download that does not match the dep's checksum file (wasmex's, and
#     exqlite's checksum.exs) is refused, and nothing is cached;
#   - a relative cache override lays each file under its dep's directory,
#     where the dep's compile finds it;
#   - a cached file that does not match is replaced by one that does;
#   - the tailwind pins hold the configured version and this machine's
#     target, the CLI laid down is the pinned one, executable, where
#     `mix tailwind prism` runs it from, its download closed; a second run
#     keeps it; a pin that does not match, and a version without one, are
#     refused with nothing laid down.
# Four controls show the closed downloads close: the wasmex compile with an
# empty cache fails at the closed port, the exqlite compile with an empty
# cache tries its download and falls back to source, the script with an
# empty cache fails at the closed port, and so does `mix tailwind prism`
# with nothing laid down.
# It downloads from GitHub, and needs the checkout's deps (mix deps.get).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
fetch="$root/scripts/fetch-prebuilt-binaries.sh"
scratch=$(mktemp -d /tmp/cyfr-fetch-prebuilt-test.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"
# The caller's Mix and cache selections are not the test's.
unset MIX_BUILD_PATH MIX_DEPS_PATH MIX_XDG RUSTLER_PRECOMPILED_FORCE_BUILD_ALL WASMEX_BUILD EXQLITE_USE_SYSTEM
export MIX_ENV=test
# elixir_make's cache is the test's for every run; rustler_precompiled's is
# given to each.
export ELIXIR_MAKE_CACHE_DIR="$scratch/emcache"
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

# Every invocation of a command whose download this script takes over, in
# a tracked file, runs the fetch next to it: each `mix deps.get` is
# followed by the fetch (on its line after `&&`, or alone on the next
# line), and each `mix assets.deploy` and `mix tailwind` is preceded by the
# tailwind fetch (on its line before `&&`, or alone on the line before, or
# in a Dockerfile in an earlier RUN of the same stage). An invocation is the
# words at a command position (a line's start, or after RUN, run:, &&, ||,
# ; or |) outside a quoted string and a comment, read a line at a time; the
# same words in a message, a comment or the docs' prose (Markdown, which
# shows commands rather than runs them) are not one. The reading is held
# first to cases that must and must not match.
python3 -I - "$root" <<'PY'
import os, re, subprocess, sys

FETCH = "scripts/fetch-prebuilt-binaries.sh"
TAILWIND = FETCH + " --tailwind"
DEPS_GET = "mix deps.get"
ASSETS = ("mix assets.deploy", "mix tailwind")

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

def invocations(lines, words):
    """(line index, start, end) of each invocation of words in lines."""
    found = []
    for n, text in enumerate(lines):
        free = outside(text)
        for m in re.finditer(re.escape(words) + r"(?![\w.-])", text):
            if m.start() not in free:
                continue
            before = text[:m.start()].rstrip()
            if before == "" or before.endswith(("&&", ";", "|", "run:")) or re.search(r"(?:^|\s)RUN$", before):
                found.append((n, m.start(), m.end()))
    return found

def followed(lines, n, end):
    rest, nxt = lines[n][end:], (lines[n + 1] if n + 1 < len(lines) else "")
    return bool(re.match(r"[^&;|]*&& " + re.escape(FETCH) + r"(?![\w.-])(?! --)", rest)) or (
        re.fullmatch(r"[^&;|]*(?:&&)?\s*\\?", rest) is not None
        and re.fullmatch(r"\s*" + re.escape(FETCH) + r"(?: &&| \\)?\s*", nxt) is not None)

def preceded(lines, n, start, dockerfile):
    before = lines[n][:start]
    if re.search(re.escape(TAILWIND) + r"\s*&&\s*$", before):
        return True
    if dockerfile:
        for k in range(n - 1, -1, -1):
            if re.match(r"\s*FROM\s", lines[k]):
                return False
            if re.fullmatch(r"\s*RUN " + re.escape(TAILWIND) + r"\s*", lines[k]):
                return True
        return False
    return before.strip() == "" and n > 0 and re.fullmatch(
        r"\s*" + re.escape(TAILWIND) + r"(?: &&| \\)?\s*", lines[n - 1]) is not None

def held(lines, dockerfile=False):
    """(line number, words, held) for each invocation in lines."""
    out = [(n + 1, DEPS_GET, followed(lines, n, e)) for n, _, e in invocations(lines, DEPS_GET)]
    for words in ASSETS:
        out += [(n + 1, words, preceded(lines, n, s, dockerfile)) for n, s, _ in invocations(lines, words)]
    return sorted(out)

# The fetch's own refusals, which name the command in a string, and the
# other words that are no invocation.
NOT = [
    '    refuse.("#{rustler_precompiled} holds no rustler_precompiled: run mix deps.get first")',
    '    refuse.("no locked dep in #{deps} calls `use RustlerPrecompiled`: run mix deps.get first, or drop this part of the script once no dep needs it")',
    "      # The fetch every job runs after mix deps.get names the file and URL",
    "- After `mix deps.get` in a fresh checkout, and after a change to",
    'SETUP_RUNS = {"mix deps.get\\nscripts/fetch-prebuilt-binaries.sh"}',
    "mix deps.getter",
    "echo then mix deps.get",
    '      "assets.deploy": ["tailwind prism --minify", "esbuild prism --minify", "phx.digest"]',
    "# Building the release runs `mix assets.deploy`, as the image's builder",
    "mix tailwind.install",
    # At a command position, and in a string or a comment all the same.
    """has_line "^test.yml static: 'run: mix deps.get; test -f x' is neither run by the gate" \\""",
    "step = '      - run: mix deps.get\\n'",
    "      # run: mix deps.get",
    "true # && mix deps.get",
    "true # && mix assets.deploy",
]
IS = [
    "mix deps.get",
    "          mix deps.get",
    "      - run: mix deps.get",
    "RUN mix deps.get --only prod && mix deps.compile",
    'cd "$root" && mix deps.get',
    "true; mix deps.get",
    "yes | mix deps.get",
    "RUN mix compile && mix assets.deploy && mix release cyfr",
    "        mix assets.deploy &&",
    "mix tailwind prism",
]
HELD = [
    (["RUN mix deps.get --only prod && scripts/fetch-prebuilt-binaries.sh && mix deps.compile"], False, True),
    (["          mix deps.get", "          scripts/fetch-prebuilt-binaries.sh"], False, True),
    (["      mix deps.get --only prod &&", "        scripts/fetch-prebuilt-binaries.sh &&"], False, True),
    (["RUN mix deps.get --only prod && mix deps.compile"], False, False),
    (["          mix deps.get", "          mix compile"], False, False),
    (["mix deps.get && mix compile", "scripts/fetch-prebuilt-binaries.sh"], False, False),
    (["mix deps.get && scripts/fetch-prebuilt-binaries.sh --tailwind"], False, False),
    (["        scripts/fetch-prebuilt-binaries.sh --tailwind &&", "        mix assets.deploy &&"], False, True),
    (["scripts/fetch-prebuilt-binaries.sh --tailwind && mix tailwind prism"], False, True),
    (["FROM x AS b", "RUN scripts/fetch-prebuilt-binaries.sh --tailwind", "COPY a b", "RUN mix compile && mix assets.deploy"], True, True),
    (["FROM x AS b", "RUN scripts/fetch-prebuilt-binaries.sh --tailwind", "FROM y AS c", "RUN mix assets.deploy"], True, False),
    (["RUN mix compile && mix assets.deploy"], True, False),
    (["        scripts/fetch-prebuilt-binaries.sh &&", "        mix assets.deploy &&"], False, False),
    (["scripts/fetch-prebuilt-binaries.sh --tailwind", "true", "mix assets.deploy"], False, False),
]
wrong = [f"read as an invocation: {t}" for t in NOT if held([t])]
wrong += [f"not read as an invocation: {t}" for t in IS if len(held([t])) != 1]
wrong += [f"read as {'not ' if want else ''}held to the fetch: {' / '.join(ls)}"
          for ls, docker, want in HELD if [h for _, _, h in held(ls, docker)] != [want]]
if wrong:
    sys.exit("FAIL: the invocation reading is wrong:\n  " + "\n  ".join(wrong))

root = sys.argv[1]
paths = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True).stdout.split(b"\0")
bad, seen = [], {}
for path in (p.decode() for p in paths if p):
    if path.endswith(".md"):
        continue
    try:
        text = open(f"{root}/{path}", encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    if DEPS_GET not in text and not any(w in text for w in ASSETS):
        continue
    lines = text.split("\n")
    for n, words, ok in held(lines, os.path.basename(path).startswith("Dockerfile")):
        seen[words] = seen.get(words, 0) + 1
        if not ok:
            bad.append(f"{path}:{n}: {lines[n - 1].strip()}")
for words in (DEPS_GET, "mix assets.deploy"):
    if not seen.get(words):
        sys.exit(f"FAIL: no tracked file invokes {words}, so the scan checked nothing of it")
if bad:
    sys.exit(f"FAIL: an invocation without its fetch ({FETCH} after mix deps.get, {TAILWIND} before mix assets.deploy and mix tailwind):\n  " + "\n  ".join(bad))
print("each invocation is held to its fetch: " + ", ".join(f"{w} {c}" for w, c in sorted(seen.items())))
PY

cache="$scratch/cache"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" > "$scratch/first.out" ||
  fail "the fetch into an empty cache failed"
RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" "$fetch" --print > "$scratch/print.out" ||
  fail "--print failed"
[ "$(cut -f1 "$scratch/print.out" | tr '\n' ' ')" = 'Wasmex.Native :exqlite :lazy_html ' ] ||
  fail "the script names other NIFs than wasmex's, exqlite's and lazy_html's, which this test holds to their downloads: $(cat "$scratch/print.out")"
grep '^Wasmex\.Native	' "$scratch/print.out" > "$scratch/wasmex.out"
IFS=$'\t' read -r module file url path < "$scratch/wasmex.out"
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
diff "$scratch/recorded.out" "$scratch/wasmex.out" > "$scratch/record.diff" ||
  fail "the script's module, file name, URL and cache path are not what rustler_precompiled recorded: $(cat "$scratch/record.diff")"

# Control: with nothing cached, the same compile fails at the closed port.
! compile_wasmex "$scratch/build-empty" "$scratch/cache-empty" > "$scratch/control.log" 2>&1 ||
  fail "wasmex compiled with nothing cached and its download closed: the compile above proves nothing"
grep -q 'econnrefused' "$scratch/control.log" ||
  fail "the control compile failed, but not at the closed port: $(tail -n 20 "$scratch/control.log")"

# exqlite and lazy_html, through elixir_make: the first fetch laid each
# archive in the test's elixir_make cache, under the name and from the URL
# elixir_make names, and a compile of both, every download closed, finds
# them: it tries no download and builds nothing from source, and each
# extracted NIF is there. Control: the same compile with nothing cached
# tries the download and falls back to a source build (make stood in, so
# the fallback ends at once).
# Compiles, in build $1 against elixir_make cache $2, elixir_make, its
# precompiler and the deps named after them, with theirs.
compile_make() {
  local build=$1 cache=$2
  shift 2
  offline MIX_BUILD_PATH="$build" ELIXIR_MAKE_CACHE_DIR="$cache" \
    mix deps.compile elixir_make cc_precompiler telemetry db_connection "$@"
}
for app in exqlite lazy_html; do
  line=$(grep "^:$app	" "$scratch/print.out") || fail "the script names no NIF of $app's: $(cat "$scratch/print.out")"
  IFS=$'\t' read -r _ em_file em_url em_path <<<"$line"
  [ "$em_path" = "$ELIXIR_MAKE_CACHE_DIR/$em_file" ] || fail "$app's cache path $em_path is not in the elixir_make cache given"
  [ -f "$em_path" ] || fail "the fetch left no $em_path"
  grep -qxF "$em_file fetched from $em_url to $em_path" "$scratch/first.out" ||
    fail "the fetch did not report $app's download: $(cat "$scratch/first.out")"
  [ "$app" != exqlite ] || { exqlite_file=$em_file exqlite_url=$em_url; }
done
compile_make "$scratch/build-make" "$ELIXIR_MAKE_CACHE_DIR" exqlite fine lazy_html > "$scratch/make.log" 2>&1 ||
  fail "exqlite and lazy_html did not compile from the fetched cache: $(tail -n 20 "$scratch/make.log")"
! grep -E 'Downloading precompiled NIF|Attempting to compile' "$scratch/make.log" ||
  fail "the compile tried a download or a source build with the archives in place"
[ -f "$scratch/build-make/lib/exqlite/priv/sqlite3_nif.so" ] && [ -f "$scratch/build-make/lib/lazy_html/priv/liblazy_html.so" ] ||
  fail "the compile extracted no NIF of exqlite's or lazy_html's"
mkdir "$scratch/nomake"
printf '#!/bin/sh\necho "make: stood in by the test" >&2\nexit 2\n' > "$scratch/nomake/make"
chmod +x "$scratch/nomake/make"
PATH="$scratch/nomake:$PATH" compile_make "$scratch/build-make-empty" "$scratch/emcache-empty" exqlite > "$scratch/make-control.log" 2>&1 || :
grep -qF "Downloading precompiled NIF to $scratch/emcache-empty/$exqlite_file" "$scratch/make-control.log" &&
  grep -qF 'Attempting to compile exqlite from source' "$scratch/make-control.log" ||
  fail "with nothing cached the compile neither tried the download nor fell back: the compile above proves nothing: $(tail -n 20 "$scratch/make-control.log")"

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

# A checksum.exs that names another sha256 for exqlite's archive: refused,
# nothing laid down in elixir_make's cache.
mkdir "$scratch/deps-make"
cp -R deps/rustler_precompiled deps/wasmex deps/elixir_make deps/cc_precompiler deps/exqlite "$scratch/deps-make/"
python3 -I - "$scratch/deps-make/exqlite/checksum.exs" "$exqlite_file" <<'PY'
import re, sys
p, name = sys.argv[1], sys.argv[2]
s = open(p).read()
t, n = re.subn(r'("' + re.escape(name) + r'" => "sha256:)[0-9a-f]{64}"', r'\g<1>' + "0" * 64 + '"', s)
assert n == 1, f"{name} is not once in {p}"
open(p, "w").write(t)
PY
status=0
MIX_DEPS_PATH="$scratch/deps-make" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$cache" ELIXIR_MAKE_CACHE_DIR="$scratch/emcache-bad" \
  "$fetch" > /dev/null 2> "$scratch/make-bad.err" || status=$?
[ "$status" -eq 1 ] || fail "an exqlite archive that does not match its checksum exited $status, not 1"
grep -qF "$exqlite_url does not match exqlite's checksum.exs" "$scratch/make-bad.err" ||
  fail "an exqlite checksum mismatch was refused without its reason: $(cat "$scratch/make-bad.err")"
[ -z "$(ls -A "$scratch/emcache-bad" 2>/dev/null)" ] ||
  fail "a refused exqlite download left $(ls -A "$scratch/emcache-bad") in the cache"

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
cp -R deps/rustler_precompiled deps/rustler deps/jason deps/wasmex deps/elixir_make deps/cc_precompiler deps/exqlite "$scratch/deps-rel/"
rel=relative-cache
(cd "$scratch/elsewhere" && MIX_DEPS_PATH="$scratch/deps-rel" RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$rel" \
  ELIXIR_MAKE_CACHE_DIR="$rel" "$fetch" --print) > "$scratch/rel-print.out" || fail "--print with a relative cache failed"
[ "$(cut -f4 "$scratch/rel-print.out" | tr '\n' ' ')" = "$scratch/deps-rel/wasmex/$rel/$file $scratch/deps-rel/exqlite/$rel/$exqlite_file " ] ||
  fail "a relative cache does not resolve under each dep's directory: $(cat "$scratch/rel-print.out")"
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
  esac > "$copy/scripts/fetch-prebuilt-binaries.sh"
  chmod +x "$copy/scripts/fetch-prebuilt-binaries.sh"
  ! cmp -s "$fetch" "$copy/scripts/fetch-prebuilt-binaries.sh" || fail "the $case copy of the script changed nothing"
  status=0
  MIX_BUILD_PATH="$scratch/tw-$case/test" "$copy/scripts/fetch-prebuilt-binaries.sh" --tailwind \
    > /dev/null 2> "$scratch/tw-$case.err" || status=$?
  [ "$status" -eq 1 ] || fail "the tailwind $case exited $status, not 1"
  [ ! -e "$scratch/tw-$case/tailwind-$tw_target-$tw_version" ] || fail "the tailwind $case laid a binary down"
done
grep -qF "$tw_url does not match the sha256 pinned for tailwind $tw_version on $tw_target" "$scratch/tw-mismatch.err" ||
  fail "a tailwind download that does not match its pin was refused without its reason: $(cat "$scratch/tw-mismatch.err")"
grep -qF "no sha256 is pinned for tailwind $tw_version on $tw_target" "$scratch/tw-unknown.err" ||
  fail "a tailwind version without a pin was refused without its reason: $(cat "$scratch/tw-unknown.err")"

[ -z "$(ls -A "$TMPDIR" | grep '^fetch-prebuilt-binaries\.')" ] || fail "a run left its scratch behind: $(ls -A "$TMPDIR")"

echo "fetch-prebuilt-binaries: the NIFs of wasmex, exqlite and lazy_html and tailwind $tw_version fetched, verified and found where their own downloads look; mismatches refused"

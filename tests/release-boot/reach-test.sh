#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The release-boot reach case's staging (tests/release-boot/boot.sh
# `reach_vectors`, `reach_settings`, `reach_vector_boot`), against a
# stand-in release that reports what it was given and refuses: for every
# boot vector a release can be given, the .env at the release's root is
# the vector's file, byte for byte as the release's reader takes it, and
# the environment merged over it, as runtime.exs merges the two, is the
# vector's process in every name a vector assigns, blank counting as
# unset, with no other of those names set. A staging that wrote another
# file, left a cell's own setting in the environment or lost a vector's
# process value fails here. No release is built and no database is
# needed.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-reach-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The stand-in release: its .env (read the one way the vectors are written,
# NAME='value') and its whole environment, as JSON, then a refusal.
mkdir -p "$scratch/release/bin" "$scratch/cell/data" "$scratch/cell/seed" "$scratch/cell/home" "$scratch/vectors"
cat >"$scratch/release/bin/cyfr" <<'SH'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I -c '
import json, os, sys
path = os.path.join(sys.argv[1], ".env")
file = None
if os.path.exists(path):
    file = {}
    for line in open(path).read().splitlines():
        name, _, value = line.partition("=")
        assert value[0] == value[-1] == "\x27", line
        file[name] = value[1:-1]
print("GIVEN=" + json.dumps({"file": file, "env": dict(os.environ), "args": sys.argv[2:]}))' "$root" "$@"
exit 1
SH
chmod +x "$scratch/release/bin/cyfr"
# A cell's settings as cyfr init writes them, reach keys among them.
cat >"$scratch/cell/.env" <<'ENV'
CYFR_SECRET_KEY_BASE=key-base
CYFR_REACH=local
CYFR_HOST=localhost
CYFR_PORT=4399
CYFR_CORS_ALLOWED_ORIGINS=
CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100
CYFR_LOCUS_BUILDS_KEY=builds-key
CYFR_BIND_ADDRESS=127.0.0.1
ENV

ADAPTER=sqlite WORK="$scratch" bash -c '
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  source "$1/tests/release-boot/boot.sh"
  source "$1/tests/release-boot/release.sh"
  count="$(reach_vectors "$1/tests/fixtures/reach_modes.json" "$2/vectors")"
  [ "$count" -gt 0 ] || fail "no vector was staged"
  reach_settings "$2/cell/.env" "$2/vectors/strip" >"$2/reach.env"
  cp "$2/reach.env" "$2/cell/.env"
  for vector in "$2"/vectors/*/; do
    vector="${vector%/}"
    reach_vector_boot "$vector" "$2/release" "$2/cell" >"$vector/given" 2>&1 && fail "$vector: the stand-in refused, yet the boot passed"
  done
  echo "$count"' _ "$root" "$scratch" >"$scratch/count"

python3 -I - "$root/tests/fixtures/reach_modes.json" "$scratch" <<'PY'
import json, os, sys
vectors, scratch = json.load(open(sys.argv[1]))["boot"], sys.argv[2]
strip = open(os.path.join(scratch, "vectors", "strip")).read().split()
cell = dict(l.split("=", 1) for l in open(os.path.join(scratch, "reach.env")).read().splitlines() if l)
leaked = [k for k in cell if k in strip]
if leaked:
    sys.exit(f"FAIL: the cell's settings keep vector names: {leaked}")
if cell.get("CYFR_SECRET_KEY_BASE") != "key-base" or cell.get("CYFR_LOCUS_BUILDS_KEY") != "builds-key":
    sys.exit(f"FAIL: the cell's own settings were lost: {cell}")
refused = [v for v in vectors if v["input"]["release?"] and "refusal" in v]
dirs = sorted(d for d in os.listdir(os.path.join(scratch, "vectors")) if d != "strip")
if len(dirs) != len(refused):
    sys.exit(f"FAIL: {len(dirs)} vectors staged, of {len(refused)} a release can be given")
blank = lambda x: x is None or x.strip() == ""
failures = []
for d, v in zip(dirs, refused):
    name = open(os.path.join(scratch, "vectors", d, "name")).read()
    if name != v["name"]:
        failures.append(f"{d} is {name!r}, not {v['name']!r}")
        continue
    lines = [l for l in open(os.path.join(scratch, "vectors", d, "given")).read().splitlines() if l.startswith("GIVEN=")]
    given = json.loads(lines[-1][len("GIVEN="):])
    if given["args"] != ["start"]:
        failures.append(f"{name}: the release was run as {given['args']}")
    if given["file"] != v["input"]["file"]:
        failures.append(f"{name}: the release read {given['file']} as its .env, not {v['input']['file']}")
    merged = dict(given["file"] or {})
    merged.update({k: val for k, val in given["env"].items() if k in strip})
    process = v["input"]["process"]
    for key in strip:
        want, got = process.get(key), merged.get(key)
        if (want is None and not blank(got)) or (want is not None and got != want):
            failures.append(f"{name}: {key} merges to {got!r}, where the vector's process holds {want!r}")
    if blank(process.get("CYFR_LOCUS_BUILDS_URL")) and not blank(given["env"].get("CYFR_LOCUS_BUILDS_KEY")):
        failures.append(f"{name}: a builds key without a builds URL")
for f in failures:
    print(f"FAIL: {f}")
if failures:
    sys.exit(1)
print(f"ok: {len(dirs)} vectors: the release's .env is each one's file and the environment merged over it is its process")
PY

# A boot refusal is the release's own exit: a stand-in that prints a
# vector's FATAL sentence and then ignores TERM is killed at the deadline
# (137), and one that ends at TERM exits 124 through the deadline; both
# fail the refusal check (`boot_refused`) that the vector loop and the
# namespace case apply to their boots, each launched under the same
# `timeout -k BOOT_KILL_AFTER BOOT_DEADLINE`. A stand-in that refuses with
# the sentence passes it, and one that exits 1 without it does not.
mkdir -p "$scratch/hang/bin" "$scratch/term/bin" "$scratch/refuse/bin" "$scratch/silent/bin"
cat >"$scratch/hang/bin/cyfr" <<'SH'
#!/usr/bin/env bash
trap '' TERM
echo "[Cyfr] FATAL: $(cat "$(dirname "$0")/../sentence")"
while :; do sleep 1; done
SH
cat >"$scratch/term/bin/cyfr" <<'SH'
#!/usr/bin/env bash
echo "[Cyfr] FATAL: $(cat "$(dirname "$0")/../sentence")"
exec sleep 600
SH
cat >"$scratch/refuse/bin/cyfr" <<'SH'
#!/usr/bin/env bash
echo "[Cyfr] FATAL: $(cat "$(dirname "$0")/../sentence")"
exit 1
SH
printf '#!/usr/bin/env bash\necho "no sentence here"\nexit 1\n' >"$scratch/silent/bin/cyfr"
first="$(find "$scratch/vectors" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
for kind in hang term refuse silent; do
  chmod +x "$scratch/$kind/bin/cyfr"
  cp "$first/sentence" "$scratch/$kind/sentence"
done
ADAPTER=sqlite WORK="$scratch" BOOT_DEADLINE=2 BOOT_KILL_AFTER=1 bash -c '
  set -uo pipefail
  source "$1/tests/release-boot/boot.sh"
  source "$1/tests/release-boot/release.sh"
  for kind in hang term refuse silent; do
    reach_vector_boot "$3" "$2/$kind" "$2/cell" >"$2/$kind.log" 2>&1
    status=$?
    if boot_refused "$status" "$2/$kind.log" "$(cat "$3/sentence")"; then echo "$kind $status refused"; else echo "$kind $status not"; fi
  done' _ "$root" "$scratch" "$first" >"$scratch/hang.out"
[ "$(cat "$scratch/hang.out")" = "$(printf '%s\n' "hang 137 not" "term 124 not" "refuse 1 refused" "silent 1 not")" ] ||
  fail "the refusal check took a boot the deadline ended, or refused a refusal: $(tr '\n' ';' <"$scratch/hang.out")"
echo "ok: a boot that prints the sentence and is ended by the deadline (137 killed, 124 at TERM) is no refusal; exit 1 with the sentence is"

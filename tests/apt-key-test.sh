#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/apt-key.sh against saved InRelease files, a stand-in archive
# (tests/apt-key-archive.py) and a stand-in apt-get on PATH: the key holds
# still when Debian signs the same indexes again and moves when a package
# does, the archive is read from the three suites' exact URLs through a
# mirror's redirect and only as release files, and the guard refuses
# lists other than the key's and any value but 0, a date or a key. It needs bash, curl, python3, sed and sha256sum, and no
# network beyond 127.0.0.1, nor Docker.
#
# tests/apt-key-release holds real InRelease files from
# snapshot.debian.org, cut to their header, their SHA256 lines for main's
# all, amd64 and arm64 Packages, and their signature (which no longer
# verifies; the key reads none): trixie as of 2026-11-21T15:00Z;
# trixie-updates signed at 02:11 and again at 08:20 on 2026-11-20 with
# the same indexes (.resigned); trixie-security as of 2026-11-22T21:00Z
# and after the next security update, 2026-11-23T21:00Z (.next).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY="$ROOT/scripts/apt-key.sh"
F="$ROOT/tests/apt-key-release"
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-apt-key-test.XXXXXX")
trap 'rm -rf "$S"' EXIT

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# The key of the saved files, as the key's definition gives it.
SAVED=e97caab28a8164322a55492f64a7bf099b42be3f613c821329d3260773fb8346
saved=("$F/trixie.InRelease" "$F/trixie-updates.InRelease" "$F/trixie-security.InRelease")

begin "the saved files' key is the definition's: each suite's codename and SHA256 lines, in order"
{
  for suite in trixie trixie-updates trixie-security; do
    echo "$suite"
    sed -n '/^SHA256:/,/^[^ ]/{/^ /p}' "$F/$suite.InRelease"
  done
} >"$S/keyed"
[ "$(sha256sum "$S/keyed" | cut -d' ' -f1)" = "$SAVED" ] || fail "the definition gives $(sha256sum "$S/keyed")"
[ "$("$KEY" --of "${saved[@]}")" = "$SAVED" ] || fail "the script gives $("$KEY" --of "${saved[@]}")"

begin "the files are told by their Codename, in any order"
[ "$("$KEY" --of "$F/trixie-security.InRelease" "$F/trixie.InRelease" "$F/trixie-updates.InRelease")" = "$SAVED" ] ||
  fail 'another order gave another key'

begin "the same indexes signed again, with a new Date, Valid-Until and signature, keep the key"
! cmp -s "$F/trixie-updates.InRelease" "$F/trixie-updates.resigned.InRelease" || fail 'the two signings are one file'
[ "$("$KEY" --of "$F/trixie.InRelease" "$F/trixie-updates.resigned.InRelease" "$F/trixie-security.InRelease")" = "$SAVED" ] ||
  fail 'a new signing moved the key'

begin "a security update moves the key, and so does one changed index line"
next=$("$KEY" --of "$F/trixie.InRelease" "$F/trixie-updates.InRelease" "$F/trixie-security.next.InRelease")
[ "$next" != "$SAVED" ] || fail 'the security update kept the key'
sed '/ main\/binary-amd64\/Packages\.xz$/{s/^ 0/ 1/;t;s/^ ./ 0/;}' "$F/trixie.InRelease" >"$S/trixie.InRelease"
! cmp -s "$F/trixie.InRelease" "$S/trixie.InRelease" || fail 'the planted change changed nothing'
[ "$("$KEY" --of "$S/trixie.InRelease" "$F/trixie-updates.InRelease" "$F/trixie-security.InRelease")" != "$SAVED" ] ||
  fail 'a changed index line kept the key'

refused() {
  local why=$1 status=0
  shift
  "$KEY" --of "$@" >/dev/null 2>"$S/err" || status=$?
  [ "$status" = 65 ] || fail "exited $status, not 65"
  grep -qF -- "$why" "$S/err" || fail "refused as: $(cat "$S/err")"
}
begin "a missing suite, one given twice, another suite and a field with no lines are refused"
refused 'no InRelease of the suite trixie-security is given' "$F/trixie.InRelease" "$F/trixie-updates.InRelease"
refused 'the suite trixie-updates is given twice' "${saved[@]}" "$F/trixie-updates.resigned.InRelease"
sed 's/^Codename: trixie$/Codename: forky/' "$F/trixie.InRelease" >"$S/forky.InRelease"
refused "is the suite 'forky', not one of trixie trixie-updates trixie-security" "${saved[@]}" "$S/forky.InRelease"
sed '/^SHA256:/,/^[^ ]/{/^ /d}' "$F/trixie.InRelease" >"$S/empty.InRelease"
refused 'has no SHA256 lines' "$S/empty.InRelease" "$F/trixie-updates.InRelease" "$F/trixie-security.InRelease"

# The stand-in archive (tests/apt-key-archive.py), read by the real curl
# through APT_KEY_MIRROR.
SRV="$S/srv"
mkdir -p "$SRV" "$S/bin"
python3 -I "$ROOT/tests/apt-key-archive.py" "$SRV" "$F" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null; rm -rf "$S"' EXIT
for _ in $(seq 1 100); do [ -s "$SRV/port" ] && break; sleep 0.1; done
[ -s "$SRV/port" ] || { echo "FAIL: the stand-in archive did not start" >&2; exit 1; }
MIRROR="http://127.0.0.1:$(cat "$SRV/port")"
answers() { rm -f "$SRV/log" "$SRV/asked"; printf '%s\n' "$@" >"$SRV/answers"; }
read_archive() { status=0; APT_KEY_MIRROR="$MIRROR" "$KEY" >"$S/out" 2>"$S/err" || status=$?; }
asked() { grep -c "^$1\$" "$SRV/log" || :; }

# A stand-in apt-get whose each update writes the lists the next line of
# $STUB_DIR/serve names into APT_KEY_LISTS, under apt's own names: saved
# (the key's), next (the archive a moment later), or fail.
cat >"$S/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
[ "$*" = update ] || exit 100
echo update >>"$STUB_DIR/apt.calls"
n=$(wc -l <"$STUB_DIR/apt.calls")
serve=$(sed -n "${n}p" "$STUB_DIR/serve")
[ -n "$serve" ] || serve=$(tail -n 1 "$STUB_DIR/serve")
[ "$serve" != fail ] || exit 100
security=trixie-security.InRelease
[ "$serve" != next ] || security=trixie-security.next.InRelease
cp "$FIXTURES/trixie.InRelease" "$APT_KEY_LISTS/deb.debian.org_debian_dists_trixie_InRelease"
cp "$FIXTURES/trixie-updates.InRelease" "$APT_KEY_LISTS/deb.debian.org_debian_dists_trixie-updates_InRelease"
cp "$FIXTURES/$security" "$APT_KEY_LISTS/deb.debian.org_debian-security_dists_trixie-security_InRelease"
STUB
chmod +x "$S/bin/apt-get"
export PATH="$S/bin:$PATH" STUB_DIR="$S/stub" FIXTURES="$F" APT_KEY_LISTS="$S/lists" APT_KEY_WAIT=0
fresh() { rm -rf "$S/stub" "$S/lists"; mkdir -p "$S/stub" "$S/lists"; : >"$S/stub/apt.calls"; printf '%s\n' "$@" >"$S/stub/serve"; }

begin "the archive is read from the three suites' URLs and keyed as the saved files are"
answers release
read_archive
[ "$status" = 0 ] && [ "$(cat "$S/out")" = "$SAVED" ] || fail "exited $status with $(cat "$S/out" "$S/err")"
printf '%s\n' /debian/dists/trixie/InRelease /debian/dists/trixie-updates/InRelease \
  /debian-security/dists/trixie-security/InRelease >"$S/want"
diff "$S/want" "$SRV/log" >/dev/null || fail "read $(tr '\n' ' ' <"$SRV/log")"

begin "a mirror's redirect to its delivery network is followed to the release file"
answers redirect
read_archive
[ "$status" = 0 ] && [ "$(cat "$S/out")" = "$SAVED" ] || fail "exited $status with $(cat "$S/out" "$S/err")"
[ "$(asked /cdn/trixie-security)" = 1 ] || fail "read $(tr '\n' ' ' <"$SRV/log")"

begin "a page that is no release file is a failed read: tried again, then the read fails naming the file"
answers page
read_archive
[ "$status" = 69 ] && [ ! -s "$S/out" ] || fail "exited $status and printed $(cat "$S/out")"
[ "$(asked /debian/dists/trixie/InRelease)" = 5 ] || fail "asked $(asked /debian/dists/trixie/InRelease) times"
grep -qxF "apt-key: could not read $MIRROR/debian/dists/trixie/InRelease from Debian's archive" "$S/err" ||
  fail "said $(cat "$S/err")"

begin "a page once, then the release file, is read on the next try"
answers page release
read_archive
[ "$status" = 0 ] && [ "$(cat "$S/out")" = "$SAVED" ] || fail "exited $status with $(cat "$S/out" "$S/err")"

begin "an archive that answers an error is tried again, then the read fails naming the file"
answers fail
read_archive
[ "$status" = 69 ] && [ ! -s "$S/out" ] || fail "exited $status and printed $(cat "$S/out")"
[ "$(asked /debian/dists/trixie/InRelease)" = 5 ] || fail "asked $(asked /debian/dists/trixie/InRelease) times"
grep -qxF "apt-key: could not read $MIRROR/debian/dists/trixie/InRelease from Debian's archive" "$S/err" ||
  fail "said $(cat "$S/err")"

guard() { status=0; "$KEY" --update "$1" >"$S/out" 2>"$S/err" || status=$?; updates=$(wc -l <"$S/stub/apt.calls"); }

begin "the guard passes lists that are the key's, after one update"
fresh saved
guard "$SAVED"
[ "$status" = 0 ] && [ "$updates" = 1 ] || fail "exited $status after $updates updates: $(cat "$S/err")"

begin "the guard refuses lists older than the key on every try, naming both keys"
fresh saved
guard "$next"
[ "$status" = 1 ] && [ "$updates" = 3 ] || fail "exited $status after $updates updates"
[ "$(grep -c "^apt-key: apt fetched the lists of key $SAVED, not $next (try [123] of 3)$" "$S/err")" = 3 ] ||
  fail "said $(cat "$S/err")"
grep -qxF "apt-key: the lists apt fetched are not the ones the key $next was read from; the layer is not built on them" "$S/err" ||
  fail "said $(cat "$S/err")"

begin "the guard refuses lists newer than the key"
fresh next
guard "$SAVED"
[ "$status" = 1 ] && [ "$updates" = 3 ] || fail "exited $status after $updates updates"

begin "the guard passes once an edge that served old lists catches up"
fresh saved next
guard "$next"
[ "$status" = 0 ] && [ "$updates" = 2 ] || fail "exited $status after $updates updates: $(cat "$S/err")"

begin "a lists directory holding another suite is refused"
fresh saved
cp "$S/forky.InRelease" "$S/lists/deb.debian.org_debian_dists_forky_InRelease"
guard "$SAVED"
[ "$status" = 65 ] || fail "exited $status"

begin "a failed apt-get update fails the guard with apt's status"
fresh fail
guard "$SAVED"
[ "$status" = 100 ] || fail "exited $status"

begin "0 or a date is a cache buster: one update, unchecked"
for buster in 0 2026-11-24; do
  fresh next
  guard "$buster"
  [ "$status" = 0 ] && [ "$updates" = 1 ] || fail "$buster: exited $status after $updates updates"
done

begin "any other value fails the layer naming it, with no update"
for wrong in '' 0801af08 2026-11-2 "${SAVED}0" "${SAVED^^}" ' 0'; do
  fresh saved
  guard "$wrong"
  [ "$status" = 65 ] && [ "$updates" = 0 ] || fail "'$wrong': exited $status after $updates updates"
  grep -qxF "apt-key: APT_REFRESH is '$wrong': not 0, a date (YYYY-MM-DD) or an archive key" "$S/err" ||
    fail "'$wrong': said $(cat "$S/err")"
done

begin "a wrong argument count is usage"
for args in "--update" "--update a b" "--of" "extra"; do
  status=0
  # shellcheck disable=SC2086 # the words are the arguments
  "$KEY" $args >/dev/null 2>&1 || status=$?
  [ "$status" = 64 ] || fail "'$args' exited $status"
done

echo "apt-key tests passed"

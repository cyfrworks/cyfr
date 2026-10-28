#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/image.sh against a toy repository with two worktrees and a
# stand-in docker that records each call and keeps each build's context
# (tests/image-stub.sh). It needs git, python3, flock and tar, and no
# Docker, database or build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-image-test.XXXXXX")
S=$(cd "$S" && pwd -P)
export ROOT S
trap 'rm -rf "$S"' EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR DOCKER_DEFAULT_PLATFORM STUB_PLATFORM PROOF_RUN_PREFIX
export GIT_CEILING_DIRECTORIES="$S" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$S/run"
export XDG_RUNTIME_DIR="$S/run"
STATE="$S/run/cyfr-image"

# shellcheck source=image-stub.sh
. "$ROOT/tests/image-stub.sh"
stub_docker

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# The tag scripts/image.sh in checkout $1 prints, with its other arguments.
tag_of() { local repo=$1; shift; (cd "$repo" && scripts/image.sh --tag-only "$@"); }
# The paths in a build's context, sorted.
context_paths() { tar -tf "$1" | grep -v '/$' | LC_ALL=C sort; }
# The newest context the stand-in kept.
last_context() { ls -1 "$DOCKER_STUB"/context.*.tar | sort -t. -k2 -n | tail -1; }
builds() { grep -c '^build ' "$DOCKER_STUB/calls" || :; }
sha256() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

toy_repo "$S/repo"
git -C "$S/repo" worktree add -q --detach "$S/wt2"
repo="$S/repo"

begin "the plan's two vectors hash to the plan's digests, from their bytes"
vector() {
  printf '.dockerignore\n100644 1111111111111111111111111111111111111111\nDockerfile.locus\n100644 2222222222222222222222222222222222222222\napps/locus/keeper/guard/cyfr-guard.sh\n100755 3333333333333333333333333333333333333333\nlinux/amd64\nAPT_REFRESH=%s\n' "$1"
}
[ "$(vector 2026-10-28 | wc -c)" = 248 ] || fail "vector 1 is $(vector 2026-10-28 | wc -c) bytes, not 248"
[ "$(vector 2026-10-28 | sha256)" = 6e204da700dfea8b5cfda80664f9f59d1a9e3461ef4a883dd9042ff623b28908 ] || fail 'vector 1 hashes otherwise'
[ "$(vector 0 | sha256)" = 71d9e76b2af4cf0ce0737f36892937c99ebd4c48794a6b5cf5e435ad57d220ba ] || fail 'vector 2 hashes otherwise'

begin "a tree shaped like the vectors gets the tag their layout gives, dated and undated"
vec="$S/vec"
git init -q -b main "$vec"
mkdir -p "$vec/scripts"
cp "$ROOT/scripts/image.sh" "$vec/scripts/"
put "$vec/.dockerignore" '**/_build/'
put "$vec/Dockerfile.locus" 'FROM scratch
COPY --chmod=0755 apps/locus/keeper/guard/cyfr-guard.sh /usr/local/bin/cyfr-guard'
put "$vec/apps/locus/keeper/guard/cyfr-guard.sh" '#!/bin/sh'
chmod 755 "$vec/apps/locus/keeper/guard/cyfr-guard.sh"
git -C "$vec" add -A
git -C "$vec" -c user.name=test -c user.email=test@invalid commit -q -m init
mkdir -p "$S/date-bin"
cat >"$S/date-bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = '-u +%F' ]; then echo 2026-10-28; else exec /bin/date "$@"; fi
EOF
chmod +x "$S/date-bin/date"
blob() { git -C "$vec" rev-parse "HEAD:$1"; }
layout() {
  printf '.dockerignore\n100644 %s\nDockerfile.locus\n100644 %s\napps/locus/keeper/guard/cyfr-guard.sh\n100755 %s\nlinux/amd64\nAPT_REFRESH=%s\n' \
    "$(blob .dockerignore)" "$(blob Dockerfile.locus)" "$(blob apps/locus/keeper/guard/cyfr-guard.sh)" "$1"
}
want=$(layout 2026-10-28 | sha256)
got=$(PATH="$S/date-bin:$PATH" tag_of "$vec" locus)
[ "$got" = "cyfr-locus:in-${want:0:20}" ] || fail "dated: $got, not cyfr-locus:in-${want:0:20}"
want=$(layout 0 | sha256)
got=$(tag_of "$vec" --undated locus)
[ "$got" = "cyfr-locus:in-${want:0:20}" ] || fail "undated: $got, not cyfr-locus:in-${want:0:20}"

begin 'the same tree in two worktrees gives one tag'
for kind in locus app; do
  [ "$(tag_of "$repo" "$kind")" = "$(tag_of "$S/wt2" "$kind")" ] || fail "the worktrees' $kind tags differ"
done
[[ $(tag_of "$repo" locus) =~ ^cyfr-locus:in-[0-9a-f]{20}$ ]] || fail "locus tag $(tag_of "$repo" locus)"
[[ $(tag_of "$repo" app) =~ ^cyfr:in-[0-9a-f]{20}$ ]] || fail "app tag $(tag_of "$repo" app)"

base_locus=$(tag_of "$repo" locus)
base_app=$(tag_of "$repo" app)
begin 'an edit under a COPY source gives a new tag'
printf '# edited\n' >>"$repo/config/config.exs"
[ "$(tag_of "$repo" locus)" != "$base_locus" ] || fail 'an edited config/config.exs kept the tag'
git -C "$repo" checkout -q -- config/config.exs
[ "$(tag_of "$repo" locus)" = "$base_locus" ] || fail 'the restored tree did not give its tag back'

begin 'an edit outside every source keeps the tag'
printf 'more\n' >>"$repo/docs/notes.txt"
[ "$(tag_of "$repo" locus)" = "$base_locus" ] || fail 'docs/notes.txt changed the locus tag'
[ "$(tag_of "$repo" app)" = "$base_app" ] || fail 'docs/notes.txt changed the app tag'
git -C "$repo" checkout -q -- docs/notes.txt

begin 'a mode change on a source gives a new tag'
chmod +x "$repo/config/config.exs"
[ "$(tag_of "$repo" locus)" != "$base_locus" ] || fail 'chmod +x config/config.exs kept the tag'
chmod -x "$repo/config/config.exs"

begin 'an untracked file under a source gives a new tag'
put "$repo/config/new.exs" 'import Config'
[ "$(tag_of "$repo" locus)" != "$base_locus" ] || fail 'an untracked config/new.exs kept the tag'
rm "$repo/config/new.exs"

begin 'an ignored file under a source keeps the tag and stays out of the context'
put "$repo/config/debug.log" 'noise'
[ "$(tag_of "$repo" locus)" = "$base_locus" ] || fail 'an ignored config/debug.log changed the tag'
out=$(cd "$repo" && scripts/image.sh locus 2>/dev/null)
[ "$out" = "$base_locus" ] || fail "the build printed $out"
context_paths "$(last_context)" >"$S/got"
printf '%s\n' .dockerignore Dockerfile.locus apps/locus/keeper/go.mod apps/locus/keeper/guard/cyfr-guard.sh \
  apps/locus/keeper/main.go config/config.exs mix.exs mix.lock | LC_ALL=C sort >"$S/want"
diff "$S/want" "$S/got" >/dev/null || fail "the locus context is not the source list: $(diff "$S/want" "$S/got" | tr '\n' ' ')"
rm "$repo/config/debug.log"

begin 'apps/*/mix.exs resolves to the mix files alone, a continued COPY line is read whole'
out=$(cd "$repo" && scripts/image.sh app 2>/dev/null)
[ "$out" = "$base_app" ] || fail "the build printed $out"
context_paths "$(last_context)" >"$S/got"
printf '%s\n' .dockerignore Dockerfile LICENSE README.md apps/locus/mix.exs apps/prima/mix.exs seed/a.txt | LC_ALL=C sort >"$S/want"
diff "$S/want" "$S/got" >/dev/null || fail "the app context is not the source list: $(diff "$S/want" "$S/got" | tr '\n' ' ')"

begin 'dated and undated builds get different tags'
[ "$(tag_of "$repo" --undated locus)" != "$base_locus" ] || fail 'the undated tag is the dated one'

begin 'each form the script does not read exits 65 naming its line'
cp "$repo/Dockerfile.locus" "$S/Dockerfile.locus.orig"
refused() {
  local line=$1 text=$2 why=$3 status=0
  cp "$S/Dockerfile.locus.orig" "$repo/Dockerfile.locus"
  printf '%s\n' "$text" >>"$repo/Dockerfile.locus"
  (cd "$repo" && scripts/image.sh --tag-only locus) >/dev/null 2>"$S/err" || status=$?
  [ "$status" = 65 ] || fail "\`$text\` exited $status, not 65"
  grep -qF "Dockerfile.locus:$line: $why" "$S/err" || fail "\`$text\` was refused as: $(cat "$S/err")"
}
refused 11 'ADD config/config.exs /x' 'ADD is not read here'
refused 11 'COPY ["config/config.exs", "/x"]' 'the JSON array form of COPY is not read here'
refused 11 'COPY <<EOF /x' 'a heredoc is not read here'
refused 11 'COPY $SOURCE /x' '`$SOURCE` holds a `$`'
refused 11 'COPY confi?/ /x' '`confi?/` holds a glob character other than a `*` within a segment'
refused 11 'COPY config/[a-z]* /x' '`config/[a-z]*` holds a glob character other than a `*` within a segment'
refused 11 'COPY **/mix.exs /x' '`**/mix.exs` holds a glob character other than a `*` within a segment'
refused 11 'COPY missing/ /x' '`missing/` resolves to no file of the tree'
refused 11 'COPY --exclude=*.md config/ /x' 'the flag `--exclude=*.md` is not read here'
refused 11 'COPY config/' 'a COPY needs a source and a destination'
refused 13 'RUN true \
  && true
COPY nothing-here /x' '`nothing-here` resolves to no file of the tree'
cp "$S/Dockerfile.locus.orig" "$repo/Dockerfile.locus"
{ printf '# escape=`\n'; cat "$S/Dockerfile.locus.orig"; } >"$repo/Dockerfile.locus"
status=0; (cd "$repo" && scripts/image.sh --tag-only locus) >/dev/null 2>"$S/err" || status=$?
[ "$status" = 65 ] && grep -qF 'Dockerfile.locus:1: the parser directive' "$S/err" || fail "an escape directive gave $status: $(cat "$S/err")"
cp "$S/Dockerfile.locus.orig" "$repo/Dockerfile.locus"
[ "$(tag_of "$repo" locus)" = "$base_locus" ] || fail 'the restored Dockerfile did not give its tag back'

begin 'a use names the calling shell, or --for PID, in <h>.uses'
undated=$(tag_of "$repo" --undated locus)
h=${undated##*:in-}
caller=$(cd "$repo" && bash -c 'tag=$(scripts/image.sh --undated locus); echo "$$"' 2>/dev/null)
grep -qxF "$caller" "$STATE/$h.uses" || fail "the uses of $h do not name the calling shell $caller: $(cat "$STATE/$h.uses")"
# A redirection makes Bash fork a subshell for the substitution; the use
# still names the shell, not that subshell.
caller=$(cd "$repo" && bash -c 'tag=$(scripts/image.sh --undated locus 2>/dev/null); echo "$$"')
grep -qxF "$caller" "$STATE/$h.uses" || fail "with a redirection the uses of $h do not name the calling shell $caller: $(cat "$STATE/$h.uses")"
(cd "$repo" && scripts/image.sh --undated --for 4242 locus) >/dev/null 2>&1
grep -qxF 4242 "$STATE/$h.uses" || fail "the uses of $h do not name --for 4242"
status=0; (cd "$repo" && scripts/image.sh --for 0x1 locus) >/dev/null 2>&1 || status=$?
[ "$status" = 64 ] || fail "--for 0x1 exited $status, not 64"

begin 'the build carries --platform with the hashed platform, whatever DOCKER_DEFAULT_PLATFORM says'
printf '# platform\n' >>"$repo/mix.exs"
: >"$DOCKER_STUB/calls"
tag=$(cd "$repo" && DOCKER_DEFAULT_PLATFORM=linux/arm64 scripts/image.sh locus 2>/dev/null)
grep -q "^build --platform linux/amd64 -f Dockerfile.locus .*--tag $tag -\$" "$DOCKER_STUB/calls" ||
  fail "the build call: $(grep '^build ' "$DOCKER_STUB/calls")"
[ "$(cd "$repo" && STUB_PLATFORM=linux/arm64 scripts/image.sh --tag-only locus)" != "$tag" ] || fail 'another platform kept the tag'
grep -q "works.cyfr.image-inputs=${tag##*:in-}" "$DOCKER_STUB/calls" || fail 'the build carries no label of its hash'

begin 'a built image is reused, by another worktree too'
out=$(cd "$S/wt2" && scripts/image.sh locus 2>"$S/err")
[ "$out" = "$base_locus" ] && grep -qxF "image: reused $base_locus" "$S/err" || fail "the second worktree said: $out $(cat "$S/err")"

begin 'two worktrees asking for one tag at once: one builds, the other waits and reuses'
git -C "$repo" checkout -q -- mix.exs
undated_app=$(tag_of "$repo" --undated app)
[ ! -e "$(image_file "$undated_app")" ] || fail 'the undated app image exists already'
: >"$DOCKER_STUB/calls"
echo 2 >"$DOCKER_STUB/build-sleep"
(cd "$repo" && scripts/image.sh --undated app >"$S/a.out" 2>"$S/a.err") & a=$!
(cd "$S/wt2" && scripts/image.sh --undated app >"$S/b.out" 2>"$S/b.err") & b=$!
wait "$a"; wait "$b"
rm "$DOCKER_STUB/build-sleep"
[ "$(builds)" = 1 ] || fail "$(builds) builds ran"
[ "$(cat "$S/a.out")" = "$undated_app" ] && [ "$(cat "$S/b.out")" = "$undated_app" ] || fail 'the two printed different tags'
[ "$(cat "$S/a.err" "$S/b.err" | grep -cxF "image: built $undated_app")" = 1 ] &&
  [ "$(cat "$S/a.err" "$S/b.err" | grep -cxF "image: reused $undated_app")" = 1 ] ||
  fail "they said: $(cat "$S/a.err" "$S/b.err" | grep '^image:' | tr '\n' ' ')"

begin '--tag-only never builds, locks or writes a use'
printf '# tag only\n' >>"$repo/mix.lock"
: >"$DOCKER_STUB/calls"
tag=$(tag_of "$repo" locus)
h=${tag##*:in-}
[ "$(builds)" = 0 ] || fail '--tag-only built'
[ ! -e "$STATE/$h.lock" ] && [ ! -e "$STATE/$h.uses" ] || fail '--tag-only made a lock or a use'

begin 'a failed build leaves no tag and no use, and exits with the build status'
echo 7 >"$DOCKER_STUB/build-fail"
status=0; (cd "$repo" && scripts/image.sh locus) >"$S/out" 2>/dev/null || status=$?
rm "$DOCKER_STUB/build-fail"
[ "$status" = 7 ] || fail "exited $status, not 7"
[ ! -s "$S/out" ] || fail "printed $(cat "$S/out")"
[ ! -e "$(image_file "$tag")" ] || fail 'the failed build left its tag'
[ ! -s "$STATE/$h.uses" ] || fail "the failed build wrote a use: $(cat "$STATE/$h.uses")"
[ -e "$STATE/$h.lock" ] || fail 'the lock file went'
git -C "$repo" checkout -q -- mix.lock

begin 'outside a checkout, or without a Docker daemon, it exits 69'
mkdir -p "$S/loose/scripts"
cp "$ROOT/scripts/image.sh" "$S/loose/scripts/"
status=0; "$S/loose/scripts/image.sh" --tag-only locus >/dev/null 2>"$S/err" || status=$?
[ "$status" = 69 ] && grep -qF 'is not inside a git checkout' "$S/err" || fail "outside a checkout: $status $(cat "$S/err")"
touch "$DOCKER_STUB/daemon-down"
status=0; tag_of "$repo" locus >/dev/null 2>"$S/err" || status=$?
rm "$DOCKER_STUB/daemon-down"
[ "$status" = 69 ] && grep -qF 'no Docker daemon answers' "$S/err" || fail "without a daemon: $status $(cat "$S/err")"

begin 'the lock directory is the runtime directory one, else a fixed one under /tmp'
[ "$(cd "$repo" && scripts/image.sh --lock-dir)" = "$S/run/cyfr-image" ] || fail "with XDG_RUNTIME_DIR: $(cd "$repo" && scripts/image.sh --lock-dir)"
[ "$(cd "$repo" && XDG_RUNTIME_DIR="$S/absent" scripts/image.sh --lock-dir)" = "/tmp/cyfr-image-$(id -u)" ] ||
  fail "without a runtime directory: $(cd "$repo" && XDG_RUNTIME_DIR="$S/absent" scripts/image.sh --lock-dir)"

[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the tests left the toy repository changed: $(git -C "$repo" status --porcelain)"
echo 'image tests passed'

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Check that the shipped canvas's dist/ is its sources' build:
#   scripts/check-seed-canvas.sh [--write]
#
# Each version under seed/components/tinctures/local/canvas is built as
# Locus's builder builds a tincture, by the builder's own build script and
# notices script, read from apps/locus/lib/locus/builder.ex: the version's
# sources (every file outside dist/ and node_modules/, as Compendium.Builds
# sends them) go to the script as a tar on its standard input, it installs
# exactly what the version's lockfile pins (npm ci), runs npm run build,
# writes the runtime packages' notices into dist/, and answers dist/ as a
# tar. It runs from a temporary copy with this host's Node, which must be
# the major the builder image installs (Dockerfile.locus), and, as the
# builder runs it, with a home of its own (its npm cache inside it) and no
# environment but the toolchain settings the builder passes on, so the
# caller's npm or Node settings build nothing different. The npm registry
# must be reachable. The answer is compared file by file and byte for byte
# with the committed dist/; --write replaces the committed dist/ with it
# instead.
#
# Exit 0 when every version's dist/ is its build, or with --write was
# written; 1 naming each file that differs, or a build that failed; 2 on a
# usage error; 69 when node or npm is missing, node is not the builder's
# major, or no build session can be started (neither setsid nor perl).
set -uo pipefail

usage() { echo "usage: $0 [--write]" >&2; exit 2; }

write=false
case "$#:${1:-}" in
  0:) ;;
  1:--write) write=true ;;
  *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root" || exit 1
. scripts/lib/contain.sh

builder=apps/locus/lib/locus/builder.ex

# The body of the builder's heredoc attribute `@$1`, without the two spaces
# of indentation Elixir strips from it.
heredoc() {
  awk -v start="  @$1 " '
    index($0, start) == 1 && /"""$/ { body = 1; next }
    body && $0 == "  \"\"\"" { found = 1; exit }
    body { sub(/^  /, ""); print }
    END { exit !found }
  ' "$builder"
}

if ! script="$(heredoc javascript_script)" || ! notices_script="$(heredoc notices_script)"; then
  echo "the builder's build and notices scripts could not be read from $builder" >&2
  exit 1
fi
notices="$(sed -n 's/^  @notices "\([^"]*\)"$/\1/p' "$builder")"
toolchain_env="$(sed -n 's/^  @toolchain_env ~w(\([A-Za-z_ ]*\))$/\1/p' "$builder")"
if [ -z "$notices" ] || [ -z "$toolchain_env" ]; then
  echo "the builder's notices file name or toolchain settings could not be read from $builder" >&2
  exit 1
fi
# The build script is a plain Elixir heredoc: read as text, it is the
# script the builder runs only while it holds no escape or interpolation.
case "$script" in
  *'\'*|*'#{'*)
    echo "the builder's build script in $builder holds an escape or an interpolation this check does not read" >&2
    exit 1 ;;
esac

# The build's home is its own, so a version manager's shims, which find
# their tools through the caller's home, are resolved first: the build runs
# the node binary itself and the npm beside it.
major="$(sed -n 's/^ARG NODE_VERSION=\([0-9]*\)\..*/\1/p' Dockerfile.locus)"
if [ -z "$major" ]; then
  echo "the builder image's Node version could not be read from Dockerfile.locus" >&2
  exit 1
fi
if ! node="$(node -p process.execPath 2>/dev/null)" || [ ! -x "$node" ]; then
  echo "node is not installed: the shipped canvas is built with Node $major and its npm" >&2
  exit 69
fi
nodebin="$(dirname "$node")"
if [ ! -x "$nodebin/npm" ]; then
  echo "npm is not installed beside $node: the shipped canvas is built with Node $major and its npm" >&2
  exit 69
fi
have="$("$node" -p 'process.versions.node')"
if [ "${have%%.*}" != "$major" ]; then
  echo "node $have is not Node $major, the major the builder image installs (Dockerfile.locus)" >&2
  exit 69
fi
# The settings the builder passes on, as the caller has them.
passed=()
for name in $toolchain_env; do
  [ -z "${!name:-}" ] || passed+=("$name=${!name}")
done

versions=()
for vdir in seed/components/tinctures/local/canvas/*/; do
  [ -f "$vdir/package.json" ] && versions+=("${vdir%/}")
done
if [ "${#versions[@]}" -eq 0 ]; then
  echo "no version of the shipped canvas has a package.json: the check would check nothing" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-seed-canvas.XXXXXX")" || exit 1
# Each build runs contained, in a session of its own, which the check waits
# for so that a stop is heard at once. On every exit a running build's
# session is stopped before the temporary copy is removed, so nothing
# writes into the copy once it is gone; if the check is killed outright,
# the session's watchdog stops it.
child=""
cleanup() {
  trap '' TERM INT
  [ -z "$child" ] || contain_stop "$child" 10 >/dev/null 2>&1
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo "==> building with node $have ($node)" >&2
failed=()
for vdir in "${versions[@]}"; do
  version="${vdir##*/}"
  out="$work/$version"
  mkdir -p "$out/home" "$out/tmp" || exit 1
  tar -C "$vdir" --exclude=dist --exclude=node_modules -cf "$out/sources.tar" . || exit 1
  echo "==> building $vdir" >&2
  # TMPDIR keeps what npm and Node write there (Node's compile cache) in
  # the temporary copy.
  contain_start -g 10 env -i HOME="$out/home" TMPDIR="$out/tmp" PATH="$nodebin:$PATH" ${passed[@]+"${passed[@]}"} \
    /bin/sh -c "$script" locus-build "$notices_script" "$notices" <"$out/sources.tar" >"$out/dist.tar" ||
    { s=$?; [ "$s" -eq 69 ] && exit 69; exit 1; }
  child=$CONTAIN_PID
  status=0
  contain_wait "$child" 0 10 || status=$?
  child=""
  if [ "$status" -ne 0 ] || ! tar -C "$out" -xf "$out/dist.tar" || [ ! -d "$out/dist" ]; then
    echo "$vdir: the build failed (status $status) or answered no dist/" >&2
    failed+=("$vdir")
    continue
  fi
  if $write; then
    rm -rf "$vdir/dist" && cp -R "$out/dist" "$vdir/dist" || exit 1
    echo "==> wrote $vdir/dist" >&2
  elif ! differs="$(diff -rq "$vdir/dist" "$out/dist" 2>&1)"; then
    echo "$vdir/dist is not the build of its sources:" >&2
    printf '%s\n' "$differs" | sed "s|$out/dist|the build's dist|g" >&2
    failed+=("$vdir")
  else
    echo "==> $vdir/dist is the build of its sources" >&2
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "not the build of its sources: ${failed[*]}" >&2
  exit 1
fi
exit 0
